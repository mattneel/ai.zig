use ai::{
    Agent, AgentConfig, CallbackFailure, OpenAiCompatibleConfig, OpenAiConfig, OpenAiLanguageApi,
    PartType, Runtime, TelemetryCallbacks, Tool, abi_version, abi_version_string, clear_telemetry,
};
use std::collections::VecDeque;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::panic::PanicHookInfo;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread::{self, JoinHandle};
use std::time::Duration;

static TEST_LOCK: Mutex<()> = Mutex::new(());

struct PanicHookGuard(Option<Box<dyn Fn(&PanicHookInfo<'_>) + Send + Sync + 'static>>);

impl PanicHookGuard {
    fn suppress() -> Self {
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(|_| {}));
        Self(Some(previous))
    }
}

impl Drop for PanicHookGuard {
    fn drop(&mut self) {
        if let Some(previous) = self.0.take() {
            std::panic::set_hook(previous);
        }
    }
}

#[derive(Clone, Debug)]
struct Request {
    path: String,
    content_type: String,
    body: Vec<u8>,
}

enum CannedResponse {
    Json(String),
    Sse(Vec<String>),
    Bytes {
        content_type: &'static str,
        body: Vec<u8>,
    },
}

struct CannedServer {
    base_url: String,
    requests: Arc<Mutex<Vec<Request>>>,
    shutdown: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl CannedServer {
    fn new(responses: Vec<CannedResponse>) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind canned server");
        listener
            .set_nonblocking(true)
            .expect("set canned server nonblocking");
        let base_url = format!("http://{}", listener.local_addr().expect("server address"));
        let requests = Arc::new(Mutex::new(Vec::new()));
        let thread_requests = Arc::clone(&requests);
        let shutdown = Arc::new(AtomicBool::new(false));
        let thread_shutdown = Arc::clone(&shutdown);
        let thread = thread::spawn(move || {
            let mut responses = VecDeque::from(responses);
            while !thread_shutdown.load(Ordering::Acquire) && !responses.is_empty() {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        let request = read_request(&mut stream);
                        lock(&thread_requests).push(request);
                        let response = responses.pop_front().expect("queued response");
                        write_response(&mut stream, response);
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(2));
                    }
                    Err(error) => panic!("canned server accept failed: {error}"),
                }
            }
        });
        Self {
            base_url,
            requests,
            shutdown,
            thread: Some(thread),
        }
    }

    fn requests(&self) -> Vec<Request> {
        lock(&self.requests).clone()
    }
}

impl Drop for CannedServer {
    fn drop(&mut self) {
        self.shutdown.store(true, Ordering::Release);
        let _ = TcpStream::connect(self.base_url.trim_start_matches("http://"));
        if let Some(thread) = self.thread.take() {
            thread.join().expect("join canned server");
        }
    }
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn read_request(stream: &mut TcpStream) -> Request {
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .expect("request timeout");
    let mut bytes = Vec::new();
    let mut chunk = [0_u8; 4096];
    let header_end = loop {
        let count = stream.read(&mut chunk).expect("read request headers");
        assert!(count > 0, "client closed before request headers");
        bytes.extend_from_slice(&chunk[..count]);
        if let Some(index) = find_subslice(&bytes, b"\r\n\r\n") {
            break index + 4;
        }
    };
    let headers = String::from_utf8_lossy(&bytes[..header_end]);
    let mut lines = headers.split("\r\n");
    let request_line = lines.next().expect("request line");
    let path = request_line
        .split_whitespace()
        .nth(1)
        .expect("request path")
        .to_owned();
    let mut content_length = 0;
    let mut content_type = String::new();
    for line in lines {
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        if name.eq_ignore_ascii_case("content-length") {
            content_length = value.trim().parse().expect("content length");
        } else if name.eq_ignore_ascii_case("content-type") {
            content_type = value.trim().to_owned();
        }
    }
    while bytes.len() < header_end + content_length {
        let count = stream.read(&mut chunk).expect("read request body");
        assert!(count > 0, "client closed before request body");
        bytes.extend_from_slice(&chunk[..count]);
    }
    Request {
        path,
        content_type,
        body: bytes[header_end..header_end + content_length].to_vec(),
    }
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

fn write_response(stream: &mut TcpStream, response: CannedResponse) {
    let (content_type, body) = match response {
        CannedResponse::Json(body) => ("application/json", body.into_bytes()),
        CannedResponse::Sse(events) => {
            let body = events
                .into_iter()
                .map(|event| format!("data: {event}\n\n"))
                .collect::<String>()
                .into_bytes();
            ("text/event-stream", body)
        }
        CannedResponse::Bytes { content_type, body } => (content_type, body),
    };
    let head = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    stream
        .write_all(head.as_bytes())
        .expect("write response head");
    stream.write_all(&body).expect("write response body");
    stream.flush().expect("flush response");
}

fn chat_response(text: &str, id: &str) -> String {
    format!(
        r#"{{"id":"{id}","created":1700000000,"model":"vendor/model","choices":[{{"message":{{"role":"assistant","content":"{text}"}},"finish_reason":"stop"}}],"usage":{{"prompt_tokens":2,"completion_tokens":2}}}}"#
    )
}

fn tool_call_response(call_id: &str) -> String {
    format!(
        r#"{{"id":"response-{call_id}","created":1700000000,"model":"vendor/model","choices":[{{"message":{{"role":"assistant","content":null,"tool_calls":[{{"id":"{call_id}","type":"function","function":{{"name":"weather","arguments":"{{\"city\":\"Paris\"}}"}}}}]}},"finish_reason":"tool_calls"}}],"usage":{{"prompt_tokens":3,"completion_tokens":2}}}}"#
    )
}

fn compatible_provider(runtime: &Runtime, server: &CannedServer) -> ai::Provider {
    let mut config = OpenAiCompatibleConfig::new("rust-v1", &server.base_url);
    config.api_key = Some("test-key");
    runtime
        .openai_compatible(config)
        .expect("openai-compatible provider")
}

#[test]
fn version_query_matches_frozen_v1() {
    let _guard = lock(&TEST_LOCK);
    assert_eq!(abi_version(), 0x0100_0000);
    assert_eq!(abi_version_string().expect("version string"), "1.0.0");
}

#[test]
fn generate_and_stream_text_keep_parent_handles_alive() {
    let _guard = lock(&TEST_LOCK);
    let server = CannedServer::new(vec![
        CannedResponse::Json(chat_response("generated", "generate-1")),
        CannedResponse::Sse(vec![
            r#"{"id":"stream-1","created":1700000001,"model":"vendor/model","choices":[{"delta":{"content":"streamed"}}]}"#.to_owned(),
            r#"{"id":"stream-1","choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":2,"completion_tokens":1}}"#.to_owned(),
            "[DONE]".to_owned(),
        ]),
        CannedResponse::Sse(vec![
            r#"{"id":"ui-1","created":1700000002,"model":"vendor/model","choices":[{"delta":{"content":"UI"}}]}"#.to_owned(),
            r#"{"id":"ui-1","choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":2,"completion_tokens":1}}"#.to_owned(),
            "[DONE]".to_owned(),
        ]),
    ]);
    let runtime = Runtime::new().expect("runtime");
    let mut config = OpenAiConfig::new("test-key");
    config.base_url = Some(&server.base_url);
    config.language_api = OpenAiLanguageApi::Chat;
    let provider = runtime.openai(config).expect("openai provider");
    let model = provider.language_model("vendor/model").expect("model");

    // The safe ownership nodes retain parents, mirroring the C retain graph.
    drop(provider);
    drop(runtime);

    let generated = model
        .generate_text(r#"{"prompt":"hello","maxRetries":0}"#, &[])
        .expect("generate text");
    assert_eq!(generated.text().expect("generated text"), "generated");
    assert_eq!(generated.total_tokens(), 4);

    let mut stream = model
        .stream_text(r#"{"prompt":"hello","maxRetries":0}"#, &[])
        .expect("stream text");
    let cancel = stream.cancel_handle();
    let text = stream
        .by_ref()
        .map(|part| part.expect("stream part"))
        .filter(|part| part.kind == PartType::TextDelta)
        .map(|part| part.text)
        .collect::<String>();
    assert_eq!(text, "streamed");
    assert!(cancel.cancel().is_ok(), "finished cancel handle is benign");
    let ui_chunks = model
        .stream_text_ui(r#"{"prompt":"hello","maxRetries":0}"#, &[])
        .expect("UI stream")
        .map(|part| part.expect("UI part"))
        .filter(|part| part.kind == PartType::UiMessage)
        .collect::<Vec<_>>();
    assert!(
        ui_chunks
            .iter()
            .any(|part| part.json.contains("text-delta"))
    );
    assert_eq!(server.requests().len(), 3);
}

#[test]
fn tool_callbacks_round_trip_and_contain_panics() {
    let _guard = lock(&TEST_LOCK);
    let _panic_hook = PanicHookGuard::suppress();
    let server = CannedServer::new(vec![
        CannedResponse::Json(tool_call_response("call-success")),
        CannedResponse::Json(chat_response("sunny answer", "success-2")),
        CannedResponse::Json(tool_call_response("call-panic")),
        CannedResponse::Json(chat_response("recovered answer", "panic-2")),
    ]);
    let runtime = Runtime::new().expect("runtime");
    let provider = compatible_provider(&runtime, &server);
    let model = provider.language_model("vendor/model").expect("model");
    let seen_inputs = Arc::new(Mutex::new(Vec::new()));
    let callback_inputs = Arc::clone(&seen_inputs);
    let weather = Tool::new(
        "weather",
        "Get weather for a city",
        r#"{"type":"object","properties":{"city":{"type":"string"}}}"#,
        move |input| {
            lock(&callback_inputs).push(input.to_owned());
            Ok(r#"{"condition":"sunny"}"#.to_owned())
        },
    );
    let generated = model
        .generate_text(
            r#"{"prompt":"Weather?","maxSteps":2,"maxRetries":0}"#,
            std::slice::from_ref(&weather),
        )
        .expect("tool generate");
    assert_eq!(generated.text().expect("tool text"), "sunny answer");
    assert_eq!(lock(&seen_inputs).as_slice(), [r#"{"city":"Paris"}"#]);

    let panicking = Tool::new(
        "weather",
        "Always panics",
        r#"{"type":"object"}"#,
        |_| -> std::result::Result<String, String> { panic!("tool exploded") },
    );
    let recovered = model
        .generate_text(
            r#"{"prompt":"Weather?","maxSteps":2,"maxRetries":0}"#,
            std::slice::from_ref(&panicking),
        )
        .expect("panic contained");
    assert_eq!(
        recovered.text().expect("recovered text"),
        "recovered answer"
    );
    assert_eq!(
        panicking.last_failure(),
        Some(CallbackFailure::Panicked("tool exploded".to_owned()))
    );

    let requests = server.requests();
    assert!(String::from_utf8_lossy(&requests[1].body).contains("sunny"));
    assert_eq!(requests.len(), 4);
}

#[test]
fn object_generation_and_stream_expose_canonical_json() {
    let _guard = lock(&TEST_LOCK);
    let server = CannedServer::new(vec![
        CannedResponse::Json(
            r#"{"id":"object-1","created":1700000000,"model":"vendor/model","choices":[{"message":{"role":"assistant","content":"{\"city\":\"Paris\"}"},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":4}}"#.to_owned(),
        ),
        CannedResponse::Sse(vec![
            r#"{"id":"object-stream","created":1700000001,"model":"vendor/model","choices":[{"delta":{"content":"{\"city\":"}}]}"#.to_owned(),
            r#"{"id":"object-stream","choices":[{"delta":{"content":"\"Paris\"}"}}]}"#.to_owned(),
            r#"{"id":"object-stream","choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":4}}"#.to_owned(),
            "[DONE]".to_owned(),
        ]),
    ]);
    let runtime = Runtime::new().expect("runtime");
    let mut config = OpenAiConfig::new("test-key");
    config.base_url = Some(&server.base_url);
    config.language_api = OpenAiLanguageApi::Chat;
    let provider = runtime.openai(config).expect("openai provider");
    let model = provider.language_model("vendor/model").expect("model");
    let schema = r#"{"type":"object","properties":{"city":{"type":"string"}},"required":["city"],"additionalProperties":false}"#;
    let generated = model
        .generate_object(r#"{"prompt":"Return a city","maxRetries":0}"#, schema)
        .expect("generate object");
    assert!(generated.json().expect("object json").contains("Paris"));

    let partials = model
        .stream_object(r#"{"prompt":"Return a city","maxRetries":0}"#, schema)
        .expect("stream object")
        .map(|part| part.expect("object part"))
        .filter(|part| part.kind == PartType::Object)
        .map(|part| part.json)
        .collect::<Vec<_>>();
    assert!(partials.last().expect("final partial").contains("Paris"));
}

#[test]
fn embedding_single_and_batch_results_are_exposed() {
    let _guard = lock(&TEST_LOCK);
    let server = CannedServer::new(vec![
        CannedResponse::Json(
            r#"{"object":"list","data":[{"object":"embedding","embedding":[0.25,0.75],"index":0}],"model":"text-embedding-test","usage":{"prompt_tokens":2,"total_tokens":2}}"#.to_owned(),
        ),
        CannedResponse::Json(
            r#"{"object":"list","data":[{"object":"embedding","embedding":[1.0,0.0],"index":0},{"object":"embedding","embedding":[0.0,1.0],"index":1}],"model":"text-embedding-test","usage":{"prompt_tokens":4,"total_tokens":4}}"#.to_owned(),
        ),
    ]);
    let runtime = Runtime::new().expect("runtime");
    let provider = compatible_provider(&runtime, &server);
    let model = provider
        .embedding_model("text-embedding-test")
        .expect("embedding model");
    let one = model
        .embed(b"hello", r#"{"maxRetries":0}"#)
        .expect("embed one");
    assert!(one.json().expect("one embedding json").contains("0.25"));
    let many = model
        .embed_many(
            &[b"one".as_slice(), b"two".as_slice()],
            r#"{"maxRetries":0,"maxParallelCalls":2}"#,
        )
        .expect("embed many");
    assert!(
        many.json()
            .expect("many embedding json")
            .contains(r#""values":["one","two"]"#)
    );
    let requests = server.requests();
    assert_eq!(requests[0].path, "/embeddings");
    assert!(String::from_utf8_lossy(&requests[1].body).contains("one"));
}

#[test]
fn agent_run_and_stream_retain_tool_closures() {
    let _guard = lock(&TEST_LOCK);
    let server = CannedServer::new(vec![
        CannedResponse::Json(tool_call_response("call-run")),
        CannedResponse::Json(chat_response("run complete", "run-2")),
        CannedResponse::Sse(vec![
            r#"{"id":"agent-stream-1","created":1700000001,"model":"vendor/model","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-stream","type":"function","function":{"name":"weather","arguments":"{\"city\":\"Paris\"}"}}]}}]}"#.to_owned(),
            r#"{"id":"agent-stream-1","choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":3,"completion_tokens":2}}"#.to_owned(),
            "[DONE]".to_owned(),
        ]),
        CannedResponse::Sse(vec![
            r#"{"id":"agent-stream-2","created":1700000002,"model":"vendor/model","choices":[{"delta":{"content":"stream complete"}}]}"#.to_owned(),
            r#"{"id":"agent-stream-2","choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":2}}"#.to_owned(),
            "[DONE]".to_owned(),
        ]),
    ]);
    let runtime = Runtime::new().expect("runtime");
    let provider = compatible_provider(&runtime, &server);
    let model = provider.language_model("vendor/model").expect("model");
    let calls = Arc::new(Mutex::new(0_usize));
    let callback_calls = Arc::clone(&calls);
    let tool = Tool::new(
        "weather",
        "Get weather",
        r#"{"type":"object"}"#,
        move |_| {
            *lock(&callback_calls) += 1;
            Ok(r#"{"condition":"sunny"}"#.to_owned())
        },
    );
    let agent = Agent::new(
        &model,
        AgentConfig::new()
            .with_tool(tool)
            .with_instructions("Use the weather tool")
            .with_max_steps(2),
    )
    .expect("agent");
    let generated = agent
        .run(r#"{"prompt":"Weather?","maxRetries":0}"#)
        .expect("agent run");
    assert_eq!(generated.text().expect("agent text"), "run complete");
    let streamed = agent
        .stream(r#"{"prompt":"Weather again?","maxRetries":0}"#)
        .expect("agent stream")
        .map(|part| part.expect("agent stream part"))
        .filter(|part| part.kind == PartType::TextDelta)
        .map(|part| part.text)
        .collect::<String>();
    assert_eq!(streamed, "stream complete");
    assert_eq!(*lock(&calls), 2);
}

#[test]
fn telemetry_receives_events_and_contains_panics() {
    let _guard = lock(&TEST_LOCK);
    let _panic_hook = PanicHookGuard::suppress();
    clear_telemetry();
    let server = CannedServer::new(vec![CannedResponse::Json(chat_response(
        "still works",
        "telemetry",
    ))]);
    let runtime = Runtime::new().expect("runtime");
    let provider = compatible_provider(&runtime, &server);
    let model = provider.language_model("vendor/model").expect("model");
    let events = Arc::new(Mutex::new(Vec::new()));
    let enters = Arc::new(Mutex::new(Vec::new()));
    let exits = Arc::new(Mutex::new(Vec::new()));
    let callback_events = Arc::clone(&events);
    let callback_enters = Arc::clone(&enters);
    let callback_exits = Arc::clone(&exits);
    let registration = runtime
        .register_telemetry(
            TelemetryCallbacks::new()
                .on_event(move |name, json| {
                    lock(&callback_events).push((name.to_owned(), json.to_owned()));
                    panic!("telemetry exploded");
                })
                .on_enter(move |scope, call_id| {
                    lock(&callback_enters).push((scope.to_owned(), call_id.to_owned()));
                    42
                })
                .on_exit(move |scope, token| {
                    lock(&callback_exits).push((scope.to_owned(), token));
                }),
        )
        .expect("telemetry registration");
    let generated = model
        .generate_text(r#"{"prompt":"hello","maxRetries":0}"#, &[])
        .expect("generation survives telemetry panic");
    assert_eq!(generated.text().expect("telemetry text"), "still works");
    assert!(!registration.callback_failures().is_empty());
    registration.unregister();
    assert!(!registration.is_active());
    clear_telemetry();
    assert!(!lock(&events).is_empty());
    assert!(!lock(&enters).is_empty());
    assert_eq!(lock(&enters).len(), lock(&exits).len());
    assert!(lock(&exits).iter().all(|(_, token)| *token == Some(42)));
}

#[test]
fn media_results_copy_blobs_and_transcription_audio_is_borrowed() {
    let _guard = lock(&TEST_LOCK);
    let server = CannedServer::new(vec![
        CannedResponse::Json(
            r#"{"created":1733837122,"data":[{"b64_json":"aGk="}],"usage":{"input_tokens":1,"output_tokens":2,"total_tokens":3}}"#.to_owned(),
        ),
        CannedResponse::Bytes {
            content_type: "audio/mpeg",
            body: b"ID3audio".to_vec(),
        },
        CannedResponse::Json(
            r#"{"text":"hello world","language":"english","duration":1.5,"segments":[{"start":0,"end":1.5,"text":"hello world"}]}"#.to_owned(),
        ),
    ]);
    let runtime = Runtime::new().expect("runtime");
    let mut config = OpenAiConfig::new("test-key");
    config.base_url = Some(&server.base_url);
    config.language_api = OpenAiLanguageApi::Chat;
    let provider = runtime.openai(config).expect("openai provider");

    let image = provider
        .image_model("gpt-image-1")
        .expect("image model")
        .generate_image(r#"{"prompt":"draw","n":1,"maxRetries":0}"#)
        .expect("generate image");
    assert_eq!(
        image.blob(0).expect("image blob"),
        ai::Blob {
            data: b"hi".to_vec(),
            media_type: "image/png".to_owned()
        }
    );
    let speech = provider
        .speech_model("gpt-4o-mini-tts")
        .expect("speech model")
        .generate_speech(r#"{"text":"hello","voice":"alloy","maxRetries":0}"#)
        .expect("generate speech");
    assert_eq!(speech.blob(0).expect("speech blob").data, b"ID3audio");
    let transcript = provider
        .transcription_model("whisper-1")
        .expect("transcription model")
        .transcribe(b"RIFFtiny", r#"{"maxRetries":0}"#)
        .expect("transcribe");
    assert!(
        transcript
            .json()
            .expect("transcription json")
            .contains("hello world")
    );
    let requests = server.requests();
    assert_eq!(requests[0].path, "/images/generations");
    assert_eq!(requests[1].path, "/audio/speech");
    assert_eq!(requests[2].path, "/audio/transcriptions");
    assert!(requests[2].content_type.starts_with("multipart/form-data"));
}
