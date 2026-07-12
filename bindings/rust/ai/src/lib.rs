//! Safe, dependency-free Rust wrapper for the ai.zig C ABI v1.
//!
//! Canonical JSON crosses the boundary as `&str`/`String`. This keeps the
//! wrapper free of a mandatory JSON implementation; applications can choose
//! serde_json or another parser without paying for two JSON stacks.

use ai_sys as sys;
use std::collections::HashMap;
use std::error::Error;
use std::ffi::{CStr, c_void};
use std::fmt;
use std::mem;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr::{self, NonNull};
use std::slice;
use std::str;
use std::sync::atomic::{AtomicPtr, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, Weak};

/// A result returned by the safe wrapper.
pub type AiResult<T> = std::result::Result<T, AiError>;

/// A status failure returned by the C ABI.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AiError {
    status: i32,
    status_name: String,
    detail: String,
}

impl AiError {
    fn from_status(status: i32, detail: String) -> Self {
        Self {
            status,
            status_name: status_name(status),
            detail,
        }
    }

    fn invalid_response(detail: impl Into<String>) -> Self {
        Self::from_status(sys::AI_INVALID_RESPONSE, detail.into())
    }

    fn abi_mismatch(found: u32) -> Self {
        Self::from_status(
            sys::AI_UNSUPPORTED,
            format!(
                "ai.zig ABI major mismatch: binding={}, library={}",
                sys::AI_ABI_VERSION_MAJOR,
                found >> 24
            ),
        )
    }

    /// The frozen numeric `ai_status` value.
    #[must_use]
    pub fn status(&self) -> i32 {
        self.status
    }

    /// The library's stable status name, or `unknown` for a newer value.
    #[must_use]
    pub fn status_name(&self) -> &str {
        &self.status_name
    }

    /// The copied runtime or stream diagnostic document, when available.
    #[must_use]
    pub fn detail(&self) -> &str {
        &self.detail
    }
}

impl fmt::Display for AiError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.detail.is_empty() {
            write!(formatter, "{}: ai.zig call failed", self.status_name)
        } else {
            write!(formatter, "{}: {}", self.status_name, self.detail)
        }
    }
}

impl Error for AiError {}

fn status_name(status: i32) -> String {
    // SAFETY: ai_status_name returns a static C string or null.
    let ptr = unsafe { sys::ai_status_name(status) };
    if ptr.is_null() {
        return "unknown".to_owned();
    }
    // SAFETY: the ABI promises a static NUL-terminated status name.
    unsafe { CStr::from_ptr(ptr) }
        .to_string_lossy()
        .into_owned()
}

fn raw_bytes(value: &[u8]) -> (*const u8, usize) {
    if value.is_empty() {
        (ptr::null(), 0)
    } else {
        (value.as_ptr(), value.len())
    }
}

fn raw_optional_str(value: Option<&str>) -> (*const u8, usize) {
    value.map_or((ptr::null(), 0), |text| raw_bytes(text.as_bytes()))
}

unsafe fn raw_slice<'a>(ptr: *const u8, len: usize) -> AiResult<&'a [u8]> {
    if len == 0 {
        return Ok(&[]);
    }
    if ptr.is_null() {
        return Err(AiError::invalid_response(
            "ai.zig returned a null pointer with a non-zero length",
        ));
    }
    // SAFETY: the caller ties the returned borrow to the documented C owner.
    Ok(unsafe { slice::from_raw_parts(ptr, len) })
}

unsafe fn raw_str<'a>(ptr: *const u8, len: usize) -> AiResult<&'a str> {
    // SAFETY: forwarded from the caller under the same owner lifetime.
    let bytes = unsafe { raw_slice(ptr, len)? };
    str::from_utf8(bytes).map_err(|error| AiError::invalid_response(error.to_string()))
}

unsafe fn ai_string_str<'a>(value: sys::ai_string) -> AiResult<&'a str> {
    // SAFETY: forwarded from the caller under the producing handle's lifetime.
    unsafe { raw_str(value.ptr, value.len) }
}

fn copy_ai_string(value: sys::ai_string) -> AiResult<String> {
    // SAFETY: the copy is completed while the documented owner is alive.
    unsafe { ai_string_str(value) }.map(str::to_owned)
}

/// Returns the loaded library's packed ABI version.
#[must_use]
pub fn abi_version() -> u32 {
    // SAFETY: pure ABI version query.
    unsafe { sys::ai_abi_version() }
}

/// Returns the loaded library's static ABI version string.
pub fn abi_version_string() -> AiResult<String> {
    // SAFETY: the returned string is static for the life of the library.
    copy_ai_string(unsafe { sys::ai_abi_version_string() })
}

/// Runtime pool limits. Zero selects the Zig runtime defaults.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct RuntimeConfig {
    pub async_limit: usize,
    pub concurrent_limit: usize,
}

struct RuntimeInner {
    handle: NonNull<sys::ai_runtime>,
}

// The C contract declares the runtime thread-safe and reference-counted.
unsafe impl Send for RuntimeInner {}
unsafe impl Sync for RuntimeInner {}

impl Drop for RuntimeInner {
    fn drop(&mut self) {
        // SAFETY: this node owns one runtime reference and drops it once.
        unsafe { sys::ai_runtime_destroy(self.handle.as_ptr()) };
    }
}

/// Owning ai.zig runtime. Children retain its private ownership node.
pub struct Runtime {
    inner: Arc<RuntimeInner>,
}

impl Runtime {
    /// Creates a runtime after verifying the loaded ABI major.
    pub fn new() -> AiResult<Self> {
        Self::with_config(RuntimeConfig::default())
    }

    /// Creates a runtime with explicit pool limits.
    pub fn with_config(config: RuntimeConfig) -> AiResult<Self> {
        let loaded = abi_version();
        if loaded >> 24 != sys::AI_ABI_VERSION_MAJOR {
            return Err(AiError::abi_mismatch(loaded));
        }

        let raw_config = sys::ai_runtime_config {
            struct_size: mem::size_of::<sys::ai_runtime_config>(),
            async_limit: config.async_limit,
            concurrent_limit: config.concurrent_limit,
        };
        let mut out = ptr::null_mut();
        // SAFETY: raw_config and out are valid for this blocking call.
        let status = unsafe { sys::ai_runtime_create(&raw_config, &mut out) };
        if status != sys::AI_OK {
            return Err(AiError::from_status(status, String::new()));
        }
        let handle = NonNull::new(out)
            .ok_or_else(|| AiError::invalid_response("runtime creation returned null"))?;
        Ok(Self {
            inner: Arc::new(RuntimeInner { handle }),
        })
    }

    /// Creates an Anthropic provider.
    pub fn anthropic(&self, config: AnthropicConfig<'_>) -> AiResult<Provider> {
        let (key_ptr, key_len) = raw_bytes(config.api_key.as_bytes());
        let (base_ptr, base_len) = raw_optional_str(config.base_url);
        let raw_config = sys::ai_anthropic_config {
            struct_size: mem::size_of::<sys::ai_anthropic_config>(),
            api_key_ptr: key_ptr,
            api_key_len: key_len,
            base_url_ptr: base_ptr,
            base_url_len: base_len,
        };
        let mut out = ptr::null_mut();
        // SAFETY: config strings remain live for this blocking constructor.
        let status = unsafe {
            sys::ai_provider_anthropic(self.inner.handle.as_ptr(), &raw_config, &mut out)
        };
        self.provider_from_call(status, out)
    }

    /// Creates an OpenRouter provider.
    pub fn openrouter(&self, config: OpenRouterConfig<'_>) -> AiResult<Provider> {
        let (key_ptr, key_len) = raw_bytes(config.api_key.as_bytes());
        let (base_ptr, base_len) = raw_optional_str(config.base_url);
        let (referer_ptr, referer_len) = raw_optional_str(config.referer);
        let (title_ptr, title_len) = raw_optional_str(config.title);
        let raw_config = sys::ai_openrouter_config {
            struct_size: mem::size_of::<sys::ai_openrouter_config>(),
            api_key_ptr: key_ptr,
            api_key_len: key_len,
            base_url_ptr: base_ptr,
            base_url_len: base_len,
            referer_ptr,
            referer_len,
            title_ptr,
            title_len,
        };
        let mut out = ptr::null_mut();
        // SAFETY: config strings remain live for this blocking constructor.
        let status = unsafe {
            sys::ai_provider_openrouter(self.inner.handle.as_ptr(), &raw_config, &mut out)
        };
        self.provider_from_call(status, out)
    }

    /// Creates a named OpenAI-compatible provider.
    pub fn openai_compatible(&self, config: OpenAiCompatibleConfig<'_>) -> AiResult<Provider> {
        let (name_ptr, name_len) = raw_bytes(config.name.as_bytes());
        let (base_ptr, base_len) = raw_bytes(config.base_url.as_bytes());
        let (key_ptr, key_len) = raw_optional_str(config.api_key);
        let raw_config = sys::ai_openai_compatible_config {
            struct_size: mem::size_of::<sys::ai_openai_compatible_config>(),
            name_ptr,
            name_len,
            base_url_ptr: base_ptr,
            base_url_len: base_len,
            api_key_ptr: key_ptr,
            api_key_len: key_len,
        };
        let mut out = ptr::null_mut();
        // SAFETY: config strings remain live for this blocking constructor.
        let status = unsafe {
            sys::ai_provider_openai_compatible(self.inner.handle.as_ptr(), &raw_config, &mut out)
        };
        self.provider_from_call(status, out)
    }

    /// Creates the native OpenAI provider.
    pub fn openai(&self, config: OpenAiConfig<'_>) -> AiResult<Provider> {
        let (key_ptr, key_len) = raw_bytes(config.api_key.as_bytes());
        let (base_ptr, base_len) = raw_optional_str(config.base_url);
        let (organization_ptr, organization_len) = raw_optional_str(config.organization);
        let (project_ptr, project_len) = raw_optional_str(config.project);
        let raw_config = sys::ai_openai_config {
            struct_size: mem::size_of::<sys::ai_openai_config>(),
            api_key_ptr: key_ptr,
            api_key_len: key_len,
            base_url_ptr: base_ptr,
            base_url_len: base_len,
            organization_ptr,
            organization_len,
            project_ptr,
            project_len,
            language_api: config.language_api.raw(),
        };
        let mut out = ptr::null_mut();
        // SAFETY: config strings remain live for this blocking constructor.
        let status =
            unsafe { sys::ai_provider_openai(self.inner.handle.as_ptr(), &raw_config, &mut out) };
        self.provider_from_call(status, out)
    }

    /// Creates the native xAI provider.
    pub fn xai(&self, config: XaiConfig<'_>) -> AiResult<Provider> {
        let (key_ptr, key_len) = raw_bytes(config.api_key.as_bytes());
        let (base_ptr, base_len) = raw_optional_str(config.base_url);
        let raw_config = sys::ai_xai_config {
            struct_size: mem::size_of::<sys::ai_xai_config>(),
            api_key_ptr: key_ptr,
            api_key_len: key_len,
            base_url_ptr: base_ptr,
            base_url_len: base_len,
        };
        let mut out = ptr::null_mut();
        // SAFETY: config strings remain live for this blocking constructor.
        let status =
            unsafe { sys::ai_provider_xai(self.inner.handle.as_ptr(), &raw_config, &mut out) };
        self.provider_from_call(status, out)
    }

    fn provider_from_call(&self, status: i32, out: *mut sys::ai_provider) -> AiResult<Provider> {
        check_runtime(&self.inner, status)?;
        let handle = NonNull::new(out)
            .ok_or_else(|| AiError::invalid_response("provider creation returned null"))?;
        Ok(Provider {
            inner: Arc::new(ProviderInner {
                handle,
                runtime: Arc::clone(&self.inner),
            }),
        })
    }

    /// Registers process-global telemetry callbacks.
    pub fn register_telemetry(
        &self,
        callbacks: TelemetryCallbacks,
    ) -> AiResult<TelemetryRegistration> {
        register_telemetry(self, callbacks)
    }
}

/// Borrowed Anthropic settings.
#[derive(Clone, Copy, Debug)]
pub struct AnthropicConfig<'a> {
    pub api_key: &'a str,
    pub base_url: Option<&'a str>,
}

impl<'a> AnthropicConfig<'a> {
    #[must_use]
    pub const fn new(api_key: &'a str) -> Self {
        Self {
            api_key,
            base_url: None,
        }
    }
}

/// Borrowed OpenRouter settings.
#[derive(Clone, Copy, Debug)]
pub struct OpenRouterConfig<'a> {
    pub api_key: &'a str,
    pub base_url: Option<&'a str>,
    pub referer: Option<&'a str>,
    pub title: Option<&'a str>,
}

impl<'a> OpenRouterConfig<'a> {
    #[must_use]
    pub const fn new(api_key: &'a str) -> Self {
        Self {
            api_key,
            base_url: None,
            referer: None,
            title: None,
        }
    }
}

/// Borrowed settings for a generic OpenAI-compatible provider.
#[derive(Clone, Copy, Debug)]
pub struct OpenAiCompatibleConfig<'a> {
    pub name: &'a str,
    pub base_url: &'a str,
    pub api_key: Option<&'a str>,
}

impl<'a> OpenAiCompatibleConfig<'a> {
    #[must_use]
    pub const fn new(name: &'a str, base_url: &'a str) -> Self {
        Self {
            name,
            base_url,
            api_key: None,
        }
    }
}

/// Native OpenAI language endpoint selection.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum OpenAiLanguageApi {
    #[default]
    Responses,
    Chat,
}

impl OpenAiLanguageApi {
    const fn raw(self) -> i32 {
        match self {
            Self::Responses => sys::AI_OPENAI_RESPONSES,
            Self::Chat => sys::AI_OPENAI_CHAT,
        }
    }
}

/// Borrowed native OpenAI settings.
#[derive(Clone, Copy, Debug)]
pub struct OpenAiConfig<'a> {
    pub api_key: &'a str,
    pub base_url: Option<&'a str>,
    pub organization: Option<&'a str>,
    pub project: Option<&'a str>,
    pub language_api: OpenAiLanguageApi,
}

impl<'a> OpenAiConfig<'a> {
    #[must_use]
    pub const fn new(api_key: &'a str) -> Self {
        Self {
            api_key,
            base_url: None,
            organization: None,
            project: None,
            language_api: OpenAiLanguageApi::Responses,
        }
    }
}

/// Borrowed native xAI settings.
#[derive(Clone, Copy, Debug)]
pub struct XaiConfig<'a> {
    pub api_key: &'a str,
    pub base_url: Option<&'a str>,
}

impl<'a> XaiConfig<'a> {
    #[must_use]
    pub const fn new(api_key: &'a str) -> Self {
        Self {
            api_key,
            base_url: None,
        }
    }
}

fn check_runtime(runtime: &RuntimeInner, status: i32) -> AiResult<()> {
    if status == sys::AI_OK {
        return Ok(());
    }
    // SAFETY: runtime remains owned while its borrowed diagnostic is copied.
    let detail = copy_ai_string(unsafe { sys::ai_runtime_last_error(runtime.handle.as_ptr()) })
        .unwrap_or_default();
    Err(AiError::from_status(status, detail))
}

struct ProviderInner {
    handle: NonNull<sys::ai_provider>,
    runtime: Arc<RuntimeInner>,
}

unsafe impl Send for ProviderInner {}
unsafe impl Sync for ProviderInner {}

impl Drop for ProviderInner {
    fn drop(&mut self) {
        // SAFETY: this node owns the provider handle. Its runtime field drops later.
        unsafe { sys::ai_provider_destroy(self.handle.as_ptr()) };
    }
}

/// Owning immutable provider handle.
pub struct Provider {
    inner: Arc<ProviderInner>,
}

struct OwnedModel<T> {
    handle: NonNull<T>,
    provider: Arc<ProviderInner>,
    destroy: unsafe extern "C" fn(*mut T),
}

unsafe impl<T> Send for OwnedModel<T> {}
unsafe impl<T> Sync for OwnedModel<T> {}

impl<T> Drop for OwnedModel<T> {
    fn drop(&mut self) {
        // SAFETY: this node owns the model handle. Its provider field drops later.
        unsafe { (self.destroy)(self.handle.as_ptr()) };
    }
}

fn create_model<T>(
    provider: &Arc<ProviderInner>,
    model_id: &str,
    create: unsafe extern "C" fn(*mut sys::ai_provider, *const u8, usize, *mut *mut T) -> i32,
    destroy: unsafe extern "C" fn(*mut T),
) -> AiResult<Arc<OwnedModel<T>>> {
    let (id_ptr, id_len) = raw_bytes(model_id.as_bytes());
    let mut out = ptr::null_mut();
    // SAFETY: model id is borrowed for this blocking constructor.
    let status = unsafe { create(provider.handle.as_ptr(), id_ptr, id_len, &mut out) };
    check_runtime(&provider.runtime, status)?;
    let handle = NonNull::new(out)
        .ok_or_else(|| AiError::invalid_response("model creation returned null"))?;
    Ok(Arc::new(OwnedModel {
        handle,
        provider: Arc::clone(provider),
        destroy,
    }))
}

impl Provider {
    pub fn language_model(&self, model_id: &str) -> AiResult<Model> {
        Ok(Model {
            inner: create_model(
                &self.inner,
                model_id,
                sys::ai_provider_language_model,
                sys::ai_model_destroy,
            )?,
        })
    }

    pub fn embedding_model(&self, model_id: &str) -> AiResult<EmbeddingModel> {
        Ok(EmbeddingModel {
            inner: create_model(
                &self.inner,
                model_id,
                sys::ai_provider_embedding_model,
                sys::ai_embedding_model_destroy,
            )?,
        })
    }

    pub fn image_model(&self, model_id: &str) -> AiResult<ImageModel> {
        Ok(ImageModel {
            inner: create_model(
                &self.inner,
                model_id,
                sys::ai_provider_image_model,
                sys::ai_image_model_destroy,
            )?,
        })
    }

    pub fn speech_model(&self, model_id: &str) -> AiResult<SpeechModel> {
        Ok(SpeechModel {
            inner: create_model(
                &self.inner,
                model_id,
                sys::ai_provider_speech_model,
                sys::ai_speech_model_destroy,
            )?,
        })
    }

    pub fn transcription_model(&self, model_id: &str) -> AiResult<TranscriptionModel> {
        Ok(TranscriptionModel {
            inner: create_model(
                &self.inner,
                model_id,
                sys::ai_provider_transcription_model,
                sys::ai_transcription_model_destroy,
            )?,
        })
    }
}

/// Owning language-model handle.
pub struct Model {
    inner: Arc<OwnedModel<sys::ai_model>>,
}

/// Owning embedding-model handle.
pub struct EmbeddingModel {
    inner: Arc<OwnedModel<sys::ai_embedding_model>>,
}

/// Owning image-model handle.
pub struct ImageModel {
    inner: Arc<OwnedModel<sys::ai_image_model>>,
}

/// Owning speech-model handle.
pub struct SpeechModel {
    inner: Arc<OwnedModel<sys::ai_speech_model>>,
}

/// Owning transcription-model handle.
pub struct TranscriptionModel {
    inner: Arc<OwnedModel<sys::ai_transcription_model>>,
}

/// A tool callback failure contained at the C boundary.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum CallbackFailure {
    Returned(String),
    Panicked(String),
}

type ToolCallback = dyn Fn(&str) -> std::result::Result<String, String> + Send + Sync + 'static;

struct ToolState {
    name: String,
    description: String,
    input_schema_json: String,
    execute: Box<ToolCallback>,
    last_failure: Mutex<Option<CallbackFailure>>,
}

/// A cloneable Rust closure exposed as an `ai_tool` callback.
#[derive(Clone)]
pub struct Tool {
    state: Arc<ToolState>,
}

impl Tool {
    pub fn new<F>(
        name: impl Into<String>,
        description: impl Into<String>,
        input_schema_json: impl Into<String>,
        execute: F,
    ) -> Self
    where
        F: Fn(&str) -> std::result::Result<String, String> + Send + Sync + 'static,
    {
        Self {
            state: Arc::new(ToolState {
                name: name.into(),
                description: description.into(),
                input_schema_json: input_schema_json.into(),
                execute: Box::new(execute),
                last_failure: Mutex::new(None),
            }),
        }
    }

    /// Returns the most recent callback error or contained panic.
    #[must_use]
    pub fn last_failure(&self) -> Option<CallbackFailure> {
        lock(&self.state.last_failure).clone()
    }

    fn raw(&self) -> sys::ai_tool {
        let (name_ptr, name_len) = raw_bytes(self.state.name.as_bytes());
        let (description_ptr, description_len) = raw_bytes(self.state.description.as_bytes());
        let (schema_ptr, schema_len) = raw_bytes(self.state.input_schema_json.as_bytes());
        sys::ai_tool {
            struct_size: mem::size_of::<sys::ai_tool>(),
            name_ptr,
            name_len,
            description_ptr,
            description_len,
            input_schema_json_ptr: schema_ptr,
            input_schema_json_len: schema_len,
            execute: Some(tool_trampoline),
            user_data: Arc::as_ptr(&self.state).cast_mut().cast::<c_void>(),
        }
    }
}

fn raw_tools(tools: &[Tool]) -> Vec<sys::ai_tool> {
    tools.iter().map(Tool::raw).collect()
}

fn raw_tool_slice(tools: &[sys::ai_tool]) -> (*const sys::ai_tool, usize) {
    if tools.is_empty() {
        (ptr::null(), 0)
    } else {
        (tools.as_ptr(), tools.len())
    }
}

unsafe extern "C" fn tool_trampoline(
    user_data: *mut c_void,
    input_json: *const u8,
    input_len: usize,
    out: *mut sys::ai_tool_result,
) -> i32 {
    if user_data.is_null() || out.is_null() {
        return sys::AI_INVALID_ARGUMENT;
    }

    // SAFETY: user_data points to a ToolState retained by the call/stream/agent.
    let state = unsafe { &*user_data.cast::<ToolState>() };
    // SAFETY: the ABI borrows valid input bytes for this callback invocation.
    let input = match unsafe { raw_str(input_json, input_len) } {
        Ok(value) => value,
        Err(error) => {
            *lock(&state.last_failure) = Some(CallbackFailure::Returned(error.to_string()));
            return sys::AI_INVALID_JSON;
        }
    };

    // Initialize every extensible output field before invoking user code.
    // SAFETY: out was validated non-null and is callback-owned for this invocation.
    unsafe {
        (*out).struct_size = mem::size_of::<sys::ai_tool_result>();
        (*out).ptr = ptr::null_mut();
        (*out).len = 0;
    }

    let outcome = catch_unwind(AssertUnwindSafe(|| (state.execute)(input)));
    let output = match outcome {
        Ok(Ok(output)) => output,
        Ok(Err(message)) => {
            *lock(&state.last_failure) = Some(CallbackFailure::Returned(message));
            return sys::AI_TOOL_ERROR;
        }
        Err(payload) => {
            *lock(&state.last_failure) = Some(CallbackFailure::Panicked(panic_message(&payload)));
            return sys::AI_TOOL_ERROR;
        }
    };

    let bytes = output.as_bytes();
    let output_ptr = if bytes.is_empty() {
        ptr::null_mut()
    } else {
        // SAFETY: ai_alloc is the required allocator for tool outputs.
        let allocated = unsafe { sys::ai_alloc(bytes.len()) };
        if allocated.is_null() {
            return sys::AI_OUT_OF_MEMORY;
        }
        // SAFETY: allocated has bytes.len() writable bytes and does not overlap input.
        unsafe { ptr::copy_nonoverlapping(bytes.as_ptr(), allocated, bytes.len()) };
        allocated
    };
    // SAFETY: out remains callback-owned until return.
    unsafe {
        (*out).ptr = output_ptr;
        (*out).len = bytes.len();
    }
    sys::AI_OK
}

fn panic_message(payload: &Box<dyn std::any::Any + Send>) -> String {
    if let Some(message) = payload.downcast_ref::<&str>() {
        (*message).to_owned()
    } else if let Some(message) = payload.downcast_ref::<String>() {
        message.clone()
    } else {
        "non-string Rust panic".to_owned()
    }
}

impl Model {
    /// Runs blocking text generation. Options are canonical JSON.
    pub fn generate_text(&self, options_json: &str, tools: &[Tool]) -> AiResult<Result> {
        let raw_tools = raw_tools(tools);
        let (tools_ptr, tools_len) = raw_tool_slice(&raw_tools);
        let (options_ptr, options_len) = raw_bytes(options_json.as_bytes());
        let mut out = ptr::null_mut();
        // SAFETY: options and descriptors stay alive for this blocking call.
        let status = unsafe {
            sys::ai_generate_text(
                self.inner.provider.runtime.handle.as_ptr(),
                self.inner.handle.as_ptr(),
                options_ptr,
                options_len,
                tools_ptr,
                tools_len,
                &mut out,
            )
        };
        Result::from_call(&self.inner.provider.runtime, status, out)
    }

    /// Starts a pull text stream. Tool closures are retained by the stream.
    pub fn stream_text(&self, options_json: &str, tools: &[Tool]) -> AiResult<Stream> {
        self.stream_text_with(sys::ai_stream_text, options_json, tools)
    }

    /// Starts a UI-message chunk stream.
    pub fn stream_text_ui(&self, options_json: &str, tools: &[Tool]) -> AiResult<Stream> {
        self.stream_text_with(sys::ai_stream_text_ui, options_json, tools)
    }

    fn stream_text_with(
        &self,
        start: unsafe extern "C" fn(
            *mut sys::ai_runtime,
            *mut sys::ai_model,
            *const u8,
            usize,
            *const sys::ai_tool,
            usize,
            *mut *mut sys::ai_stream,
        ) -> i32,
        options_json: &str,
        tools: &[Tool],
    ) -> AiResult<Stream> {
        let kept_tools = tools.to_vec();
        let raw_tools = raw_tools(&kept_tools);
        let (tools_ptr, tools_len) = raw_tool_slice(&raw_tools);
        let (options_ptr, options_len) = raw_bytes(options_json.as_bytes());
        let mut out = ptr::null_mut();
        // SAFETY: inputs stay alive until the stream constructor returns.
        let status = unsafe {
            start(
                self.inner.provider.runtime.handle.as_ptr(),
                self.inner.handle.as_ptr(),
                options_ptr,
                options_len,
                tools_ptr,
                tools_len,
                &mut out,
            )
        };
        check_runtime(&self.inner.provider.runtime, status)?;
        Stream::new(
            out,
            StreamOwner::Model {
                _model: Arc::clone(&self.inner),
                _tools: kept_tools,
                _raw_tools: raw_tools,
            },
        )
    }

    /// Runs blocking structured-object generation with a raw JSON Schema.
    pub fn generate_object(&self, options_json: &str, schema_json: &str) -> AiResult<Result> {
        let (options_ptr, options_len) = raw_bytes(options_json.as_bytes());
        let (schema_ptr, schema_len) = raw_bytes(schema_json.as_bytes());
        let mut out = ptr::null_mut();
        // SAFETY: options/schema stay alive for this blocking call.
        let status = unsafe {
            sys::ai_generate_object(
                self.inner.provider.runtime.handle.as_ptr(),
                self.inner.handle.as_ptr(),
                options_ptr,
                options_len,
                schema_ptr,
                schema_len,
                &mut out,
            )
        };
        Result::from_call(&self.inner.provider.runtime, status, out)
    }

    /// Starts a structured-object pull stream.
    pub fn stream_object(&self, options_json: &str, schema_json: &str) -> AiResult<Stream> {
        let (options_ptr, options_len) = raw_bytes(options_json.as_bytes());
        let (schema_ptr, schema_len) = raw_bytes(schema_json.as_bytes());
        let mut out = ptr::null_mut();
        // SAFETY: options/schema stay alive until the constructor returns.
        let status = unsafe {
            sys::ai_stream_object(
                self.inner.provider.runtime.handle.as_ptr(),
                self.inner.handle.as_ptr(),
                options_ptr,
                options_len,
                schema_ptr,
                schema_len,
                &mut out,
            )
        };
        check_runtime(&self.inner.provider.runtime, status)?;
        Stream::new(
            out,
            StreamOwner::Model {
                _model: Arc::clone(&self.inner),
                _tools: Vec::new(),
                _raw_tools: Vec::new(),
            },
        )
    }
}

impl EmbeddingModel {
    pub fn embed(&self, value: &[u8], options_json: &str) -> AiResult<Result> {
        let (value_ptr, value_len) = raw_bytes(value);
        let (options_ptr, options_len) = raw_bytes(options_json.as_bytes());
        let mut out = ptr::null_mut();
        // SAFETY: borrowed inputs stay alive for this blocking call.
        let status = unsafe {
            sys::ai_embed(
                self.inner.provider.runtime.handle.as_ptr(),
                self.inner.handle.as_ptr(),
                value_ptr,
                value_len,
                options_ptr,
                options_len,
                &mut out,
            )
        };
        Result::from_call(&self.inner.provider.runtime, status, out)
    }

    pub fn embed_many(&self, values: &[&[u8]], options_json: &str) -> AiResult<Result> {
        let raw_values: Vec<_> = values
            .iter()
            .map(|value| {
                let (ptr, len) = raw_bytes(value);
                sys::ai_string { ptr, len }
            })
            .collect();
        let values_ptr = if raw_values.is_empty() {
            ptr::null()
        } else {
            raw_values.as_ptr()
        };
        let (options_ptr, options_len) = raw_bytes(options_json.as_bytes());
        let mut out = ptr::null_mut();
        // SAFETY: value views and options stay alive for this blocking call.
        let status = unsafe {
            sys::ai_embed_many(
                self.inner.provider.runtime.handle.as_ptr(),
                self.inner.handle.as_ptr(),
                values_ptr,
                raw_values.len(),
                options_ptr,
                options_len,
                &mut out,
            )
        };
        Result::from_call(&self.inner.provider.runtime, status, out)
    }
}

impl ImageModel {
    pub fn generate_image(&self, options_json: &str) -> AiResult<Result> {
        let (options_ptr, options_len) = raw_bytes(options_json.as_bytes());
        let mut out = ptr::null_mut();
        // SAFETY: options stay alive for this blocking call.
        let status = unsafe {
            sys::ai_generate_image(
                self.inner.provider.runtime.handle.as_ptr(),
                self.inner.handle.as_ptr(),
                options_ptr,
                options_len,
                &mut out,
            )
        };
        Result::from_call(&self.inner.provider.runtime, status, out)
    }
}

impl SpeechModel {
    pub fn generate_speech(&self, options_json: &str) -> AiResult<Result> {
        let (options_ptr, options_len) = raw_bytes(options_json.as_bytes());
        let mut out = ptr::null_mut();
        // SAFETY: options stay alive for this blocking call.
        let status = unsafe {
            sys::ai_generate_speech(
                self.inner.provider.runtime.handle.as_ptr(),
                self.inner.handle.as_ptr(),
                options_ptr,
                options_len,
                &mut out,
            )
        };
        Result::from_call(&self.inner.provider.runtime, status, out)
    }
}

impl TranscriptionModel {
    pub fn transcribe(&self, audio: &[u8], options_json: &str) -> AiResult<Result> {
        let (audio_ptr, audio_len) = raw_bytes(audio);
        let (options_ptr, options_len) = raw_bytes(options_json.as_bytes());
        let mut out = ptr::null_mut();
        // SAFETY: audio/options stay alive for this blocking call.
        let status = unsafe {
            sys::ai_transcribe(
                self.inner.provider.runtime.handle.as_ptr(),
                self.inner.handle.as_ptr(),
                audio_ptr,
                audio_len,
                options_ptr,
                options_len,
                &mut out,
            )
        };
        Result::from_call(&self.inner.provider.runtime, status, out)
    }
}

/// An owning result handle with borrowed string getters and copied blobs.
pub struct Result {
    handle: NonNull<sys::ai_result>,
    _runtime: Arc<RuntimeInner>,
}

unsafe impl Send for Result {}
unsafe impl Sync for Result {}

impl Result {
    fn from_call(
        runtime: &Arc<RuntimeInner>,
        status: i32,
        out: *mut sys::ai_result,
    ) -> AiResult<Self> {
        check_runtime(runtime, status)?;
        let handle = NonNull::new(out)
            .ok_or_else(|| AiError::invalid_response("result call returned null"))?;
        Ok(Self {
            handle,
            _runtime: Arc::clone(runtime),
        })
    }

    /// Canonical result JSON, borrowed until this result is dropped.
    pub fn json(&self) -> AiResult<&str> {
        // SAFETY: the C result owns the returned bytes for self's lifetime.
        unsafe { ai_string_str(sys::ai_result_json(self.handle.as_ptr())) }
    }

    /// Generated text, borrowed until this result is dropped.
    pub fn text(&self) -> AiResult<&str> {
        // SAFETY: the C result owns the returned bytes for self's lifetime.
        unsafe { ai_string_str(sys::ai_result_text(self.handle.as_ptr())) }
    }

    /// Unified finish reason, borrowed until this result is dropped.
    pub fn finish_reason(&self) -> AiResult<&str> {
        // SAFETY: the C result owns the returned bytes for self's lifetime.
        unsafe { ai_string_str(sys::ai_result_finish_reason(self.handle.as_ptr())) }
    }

    #[must_use]
    pub fn total_tokens(&self) -> u64 {
        // SAFETY: immutable getter while self owns the handle.
        unsafe { sys::ai_result_total_tokens(self.handle.as_ptr()) }
    }

    #[must_use]
    pub fn blob_count(&self) -> usize {
        // SAFETY: immutable getter while self owns the handle.
        unsafe { sys::ai_result_blob_count(self.handle.as_ptr()) }
    }

    /// Copies one library-owned media blob into Rust-owned storage.
    pub fn blob(&self, index: usize) -> AiResult<Blob> {
        let mut buffer = sys::ai_buffer {
            struct_size: mem::size_of::<sys::ai_buffer>(),
            ptr: ptr::null_mut(),
            len: 0,
        };
        // SAFETY: output prefix is initialized and self owns the result.
        let status = unsafe { sys::ai_result_blob(self.handle.as_ptr(), index, &mut buffer) };
        if status != sys::AI_OK {
            return Err(AiError::from_status(status, String::new()));
        }
        let guard = BufferGuard(buffer);
        // SAFETY: a successful blob call returns valid bytes until ai_buf_free.
        let data = unsafe { raw_slice(guard.0.ptr, guard.0.len)? }.to_vec();
        // SAFETY: media type is borrowed from the result, which is still alive.
        let media_type =
            copy_ai_string(unsafe { sys::ai_result_blob_media_type(self.handle.as_ptr(), index) })?;
        Ok(Blob { data, media_type })
    }

    pub fn blobs(&self) -> AiResult<Vec<Blob>> {
        (0..self.blob_count())
            .map(|index| self.blob(index))
            .collect()
    }
}

impl Drop for Result {
    fn drop(&mut self) {
        // SAFETY: this value uniquely owns the result handle.
        unsafe { sys::ai_result_destroy(self.handle.as_ptr()) };
    }
}

struct BufferGuard(sys::ai_buffer);

impl Drop for BufferGuard {
    fn drop(&mut self) {
        if !self.0.ptr.is_null() {
            // SAFETY: the pair came from ai_result_blob and is freed once.
            unsafe { sys::ai_buf_free(self.0.ptr, self.0.len) };
        }
    }
}

/// Rust-owned copy of a media blob.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Blob {
    pub data: Vec<u8>,
    pub media_type: String,
}

/// Stable stream-part classification with forward-compatible unknown values.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PartType {
    TextStart,
    TextEnd,
    TextDelta,
    ReasoningStart,
    ReasoningEnd,
    ReasoningDelta,
    Custom,
    ToolInputStart,
    ToolInputEnd,
    ToolInputDelta,
    Source,
    File,
    ReasoningFile,
    ToolCall,
    ToolResult,
    ToolError,
    ToolOutputDenied,
    ToolApprovalRequest,
    ToolApprovalResponse,
    StartStep,
    FinishStep,
    Start,
    Finish,
    Abort,
    Error,
    Raw,
    Object,
    UiMessage,
    Unknown(i32),
}

impl PartType {
    fn from_raw(value: i32) -> Self {
        match value {
            sys::AI_PART_TEXT_START => Self::TextStart,
            sys::AI_PART_TEXT_END => Self::TextEnd,
            sys::AI_PART_TEXT_DELTA => Self::TextDelta,
            sys::AI_PART_REASONING_START => Self::ReasoningStart,
            sys::AI_PART_REASONING_END => Self::ReasoningEnd,
            sys::AI_PART_REASONING_DELTA => Self::ReasoningDelta,
            sys::AI_PART_CUSTOM => Self::Custom,
            sys::AI_PART_TOOL_INPUT_START => Self::ToolInputStart,
            sys::AI_PART_TOOL_INPUT_END => Self::ToolInputEnd,
            sys::AI_PART_TOOL_INPUT_DELTA => Self::ToolInputDelta,
            sys::AI_PART_SOURCE => Self::Source,
            sys::AI_PART_FILE => Self::File,
            sys::AI_PART_REASONING_FILE => Self::ReasoningFile,
            sys::AI_PART_TOOL_CALL => Self::ToolCall,
            sys::AI_PART_TOOL_RESULT => Self::ToolResult,
            sys::AI_PART_TOOL_ERROR => Self::ToolError,
            sys::AI_PART_TOOL_OUTPUT_DENIED => Self::ToolOutputDenied,
            sys::AI_PART_TOOL_APPROVAL_REQUEST => Self::ToolApprovalRequest,
            sys::AI_PART_TOOL_APPROVAL_RESPONSE => Self::ToolApprovalResponse,
            sys::AI_PART_START_STEP => Self::StartStep,
            sys::AI_PART_FINISH_STEP => Self::FinishStep,
            sys::AI_PART_START => Self::Start,
            sys::AI_PART_FINISH => Self::Finish,
            sys::AI_PART_ABORT => Self::Abort,
            sys::AI_PART_ERROR => Self::Error,
            sys::AI_PART_RAW => Self::Raw,
            sys::AI_PART_OBJECT => Self::Object,
            sys::AI_PART_UI_MESSAGE => Self::UiMessage,
            other => Self::Unknown(other),
        }
    }
}

/// Owned copy of a borrowed C stream part.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Part {
    pub kind: PartType,
    pub json: String,
    pub text: String,
}

enum StreamOwner {
    Model {
        _model: Arc<OwnedModel<sys::ai_model>>,
        _tools: Vec<Tool>,
        _raw_tools: Vec<sys::ai_tool>,
    },
    Agent {
        _agent: Arc<AgentInner>,
    },
}

struct StreamInner {
    handle: NonNull<sys::ai_stream>,
    _owner: StreamOwner,
}

unsafe impl Send for StreamInner {}
unsafe impl Sync for StreamInner {}

impl StreamInner {
    fn cancel(&self) -> AiResult<()> {
        // SAFETY: cancellation is explicitly thread-safe for a live stream.
        let status = unsafe { sys::ai_stream_cancel(self.handle.as_ptr()) };
        if status == sys::AI_OK {
            return Ok(());
        }
        // SAFETY: stream remains alive while its diagnostic is copied.
        let detail = copy_ai_string(unsafe { sys::ai_stream_last_error(self.handle.as_ptr()) })
            .unwrap_or_default();
        Err(AiError::from_status(status, detail))
    }
}

impl Drop for StreamInner {
    fn drop(&mut self) {
        // Safe Rust cannot drop Stream while next() borrows it. Cancel first,
        // then destroy; weak cancel handles cannot keep this node alive.
        let _ = self.cancel();
        // SAFETY: the sole strong owner is dropping after any next() returned.
        unsafe { sys::ai_stream_destroy(self.handle.as_ptr()) };
    }
}

/// One-consumer pull stream. Implements `Iterator<Item = AiResult<Part>>`.
pub struct Stream {
    inner: Arc<StreamInner>,
    done: bool,
}

impl Stream {
    fn new(handle: *mut sys::ai_stream, owner: StreamOwner) -> AiResult<Self> {
        let handle = NonNull::new(handle)
            .ok_or_else(|| AiError::invalid_response("stream creation returned null"))?;
        Ok(Self {
            inner: Arc::new(StreamInner {
                handle,
                _owner: owner,
            }),
            done: false,
        })
    }

    /// Requests cancellation from the current thread.
    pub fn cancel(&self) -> AiResult<()> {
        self.inner.cancel()
    }

    /// Returns a weak, thread-safe cancellation handle for racing a blocked pull.
    #[must_use]
    pub fn cancel_handle(&self) -> StreamCancel {
        StreamCancel {
            inner: Arc::downgrade(&self.inner),
        }
    }
}

impl Iterator for Stream {
    type Item = AiResult<Part>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.done {
            return None;
        }
        let mut part = sys::ai_part {
            struct_size: mem::size_of::<sys::ai_part>(),
            r#type: sys::AI_PART_UNKNOWN,
            json_ptr: ptr::null(),
            json_len: 0,
            text_ptr: ptr::null(),
            text_len: 0,
        };
        // SAFETY: &mut self enforces the one-consumer next contract.
        let status = unsafe { sys::ai_stream_next(self.inner.handle.as_ptr(), &mut part) };
        if status == sys::AI_STREAM_DONE {
            self.done = true;
            return None;
        }
        if status != sys::AI_OK {
            self.done = true;
            // SAFETY: stream remains live while its diagnostic is copied.
            let detail =
                copy_ai_string(unsafe { sys::ai_stream_last_error(self.inner.handle.as_ptr()) })
                    .unwrap_or_default();
            return Some(Err(AiError::from_status(status, detail)));
        }

        // Copy both borrowed fields before the next call can invalidate them.
        // SAFETY: the current part's bytes are valid until the next pull.
        let json = unsafe { raw_str(part.json_ptr, part.json_len) }.map(str::to_owned);
        // SAFETY: same part-borrow contract as json.
        let text = unsafe { raw_str(part.text_ptr, part.text_len) }.map(str::to_owned);
        Some(json.and_then(|json| {
            text.map(|text| Part {
                kind: PartType::from_raw(part.r#type),
                json,
                text,
            })
        }))
    }
}

impl Drop for Stream {
    fn drop(&mut self) {
        if !self.done {
            let _ = self.inner.cancel();
        }
    }
}

/// A weak cancellation capability that never outlives the stream handle.
#[derive(Clone)]
pub struct StreamCancel {
    inner: Weak<StreamInner>,
}

impl StreamCancel {
    pub fn cancel(&self) -> AiResult<()> {
        if let Some(inner) = self.inner.upgrade() {
            inner.cancel()
        } else {
            Ok(())
        }
    }
}

/// Reusable agent construction settings.
pub struct AgentConfig {
    pub tools: Vec<Tool>,
    pub instructions: Option<String>,
    pub max_steps: u32,
}

impl AgentConfig {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    #[must_use]
    pub fn with_tool(mut self, tool: Tool) -> Self {
        self.tools.push(tool);
        self
    }

    #[must_use]
    pub fn with_instructions(mut self, instructions: impl Into<String>) -> Self {
        self.instructions = Some(instructions.into());
        self
    }

    #[must_use]
    pub fn with_max_steps(mut self, max_steps: u32) -> Self {
        self.max_steps = max_steps;
        self
    }
}

impl Default for AgentConfig {
    fn default() -> Self {
        Self {
            tools: Vec::new(),
            instructions: None,
            max_steps: 20,
        }
    }
}

struct AgentInner {
    handle: NonNull<sys::ai_agent>,
    model: Arc<OwnedModel<sys::ai_model>>,
    _tools: Vec<Tool>,
    _raw_tools: Vec<sys::ai_tool>,
    _instructions: Option<String>,
}

unsafe impl Send for AgentInner {}
unsafe impl Sync for AgentInner {}

impl Drop for AgentInner {
    fn drop(&mut self) {
        // SAFETY: this node owns the agent; callback/model fields drop later.
        unsafe { sys::ai_agent_destroy(self.handle.as_ptr()) };
    }
}

/// Owning reusable agent handle.
pub struct Agent {
    inner: Arc<AgentInner>,
}

impl Agent {
    pub fn new(model: &Model, config: AgentConfig) -> AiResult<Self> {
        if config.max_steps == 0 {
            return Err(AiError::from_status(
                sys::AI_INVALID_ARGUMENT,
                "max_steps must be at least one".to_owned(),
            ));
        }
        let raw_tools = raw_tools(&config.tools);
        let (tools_ptr, tools_len) = raw_tool_slice(&raw_tools);
        let (system_ptr, system_len) = raw_optional_str(config.instructions.as_deref());
        let raw_config = sys::ai_agent_config {
            struct_size: mem::size_of::<sys::ai_agent_config>(),
            tools: tools_ptr,
            tools_len,
            system_ptr,
            system_len,
            max_steps: config.max_steps,
        };
        let mut out = ptr::null_mut();
        // SAFETY: config storage remains valid for construction and retained
        // callback strings/user_data are moved into AgentInner afterward.
        let status = unsafe {
            sys::ai_agent_create(
                model.inner.provider.runtime.handle.as_ptr(),
                model.inner.handle.as_ptr(),
                &raw_config,
                &mut out,
            )
        };
        check_runtime(&model.inner.provider.runtime, status)?;
        let handle = NonNull::new(out)
            .ok_or_else(|| AiError::invalid_response("agent creation returned null"))?;
        Ok(Self {
            inner: Arc::new(AgentInner {
                handle,
                model: Arc::clone(&model.inner),
                _tools: config.tools,
                _raw_tools: raw_tools,
                _instructions: config.instructions,
            }),
        })
    }

    pub fn run(&self, options_json: &str) -> AiResult<Result> {
        let (options_ptr, options_len) = raw_bytes(options_json.as_bytes());
        let mut out = ptr::null_mut();
        // SAFETY: options stay alive for this blocking call.
        let status = unsafe {
            sys::ai_agent_run(
                self.inner.handle.as_ptr(),
                options_ptr,
                options_len,
                &mut out,
            )
        };
        Result::from_call(&self.inner.model.provider.runtime, status, out)
    }

    pub fn stream(&self, options_json: &str) -> AiResult<Stream> {
        let (options_ptr, options_len) = raw_bytes(options_json.as_bytes());
        let mut out = ptr::null_mut();
        // SAFETY: options stay alive until the stream constructor returns.
        let status = unsafe {
            sys::ai_agent_stream(
                self.inner.handle.as_ptr(),
                options_ptr,
                options_len,
                &mut out,
            )
        };
        check_runtime(&self.inner.model.provider.runtime, status)?;
        Stream::new(
            out,
            StreamOwner::Agent {
                _agent: Arc::clone(&self.inner),
            },
        )
    }
}

type TelemetryEvent = dyn Fn(&str, &str) + Send + Sync + 'static;
type TelemetryEnter = dyn Fn(&str, &str) -> usize + Send + Sync + 'static;
type TelemetryExit = dyn Fn(&str, Option<usize>) + Send + Sync + 'static;

/// Builder for optional telemetry closures.
#[derive(Default)]
pub struct TelemetryCallbacks {
    on_event: Option<Box<TelemetryEvent>>,
    enter: Option<Box<TelemetryEnter>>,
    exit: Option<Box<TelemetryExit>>,
}

impl TelemetryCallbacks {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    #[must_use]
    pub fn on_event<F>(mut self, callback: F) -> Self
    where
        F: Fn(&str, &str) + Send + Sync + 'static,
    {
        self.on_event = Some(Box::new(callback));
        self
    }

    #[must_use]
    pub fn on_enter<F>(mut self, callback: F) -> Self
    where
        F: Fn(&str, &str) -> usize + Send + Sync + 'static,
    {
        self.enter = Some(Box::new(callback));
        self
    }

    #[must_use]
    pub fn on_exit<F>(mut self, callback: F) -> Self
    where
        F: Fn(&str, Option<usize>) + Send + Sync + 'static,
    {
        self.exit = Some(Box::new(callback));
        self
    }

    fn is_empty(&self) -> bool {
        self.on_event.is_none() && self.enter.is_none() && self.exit.is_none()
    }
}

struct TelemetryState {
    callbacks: TelemetryCallbacks,
    failures: Mutex<Vec<String>>,
    tokens: Mutex<HashMap<usize, usize>>,
    next_token: AtomicUsize,
}

struct TelemetryEntry {
    handle: AtomicPtr<sys::ai_telemetry_registration>,
    state: Arc<TelemetryState>,
    _vtable: Box<sys::ai_telemetry_vtable>,
    _runtime: Arc<RuntimeInner>,
}

unsafe impl Send for TelemetryEntry {}
unsafe impl Sync for TelemetryEntry {}

fn telemetry_registry() -> &'static Mutex<Vec<Arc<TelemetryEntry>>> {
    static REGISTRY: OnceLock<Mutex<Vec<Arc<TelemetryEntry>>>> = OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(Vec::new()))
}

fn register_telemetry(
    runtime: &Runtime,
    callbacks: TelemetryCallbacks,
) -> AiResult<TelemetryRegistration> {
    if callbacks.is_empty() {
        return Err(AiError::from_status(
            sys::AI_INVALID_ARGUMENT,
            "telemetry requires at least one callback".to_owned(),
        ));
    }

    let state = Arc::new(TelemetryState {
        callbacks,
        failures: Mutex::new(Vec::new()),
        tokens: Mutex::new(HashMap::new()),
        next_token: AtomicUsize::new(1),
    });
    let vtable = Box::new(sys::ai_telemetry_vtable {
        struct_size: mem::size_of::<sys::ai_telemetry_vtable>(),
        user_data: Arc::as_ptr(&state).cast_mut().cast::<c_void>(),
        on_event: state
            .callbacks
            .on_event
            .as_ref()
            .map(|_| telemetry_event_trampoline as _),
        enter: state
            .callbacks
            .enter
            .as_ref()
            .map(|_| telemetry_enter_trampoline as _),
        exit: state
            .callbacks
            .exit
            .as_ref()
            .map(|_| telemetry_exit_trampoline as _),
    });
    let mut out = ptr::null_mut();
    // SAFETY: vtable/state are heap-stable and retained through global clear.
    let status =
        unsafe { sys::ai_telemetry_register(runtime.inner.handle.as_ptr(), &*vtable, &mut out) };
    check_runtime(&runtime.inner, status)?;
    let handle = NonNull::new(out)
        .ok_or_else(|| AiError::invalid_response("telemetry registration returned null"))?;
    let entry = Arc::new(TelemetryEntry {
        handle: AtomicPtr::new(handle.as_ptr()),
        state,
        _vtable: vtable,
        _runtime: Arc::clone(&runtime.inner),
    });
    lock(telemetry_registry()).push(Arc::clone(&entry));
    Ok(TelemetryRegistration { entry })
}

unsafe extern "C" fn telemetry_event_trampoline(
    user_data: *mut c_void,
    event_name: *const u8,
    event_name_len: usize,
    event_json: *const u8,
    event_json_len: usize,
) {
    if user_data.is_null() {
        return;
    }
    // SAFETY: state is retained globally until ai_telemetry_clear returns.
    let state = unsafe { &*user_data.cast::<TelemetryState>() };
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: telemetry byte views are valid for this invocation.
        let name = String::from_utf8_lossy(unsafe {
            raw_slice(event_name, event_name_len).unwrap_or_default()
        });
        // SAFETY: telemetry byte views are valid for this invocation.
        let json = String::from_utf8_lossy(unsafe {
            raw_slice(event_json, event_json_len).unwrap_or_default()
        });
        if let Some(callback) = &state.callbacks.on_event {
            callback(&name, &json);
        }
    }));
    if let Err(payload) = outcome {
        lock(&state.failures).push(panic_message(&payload));
    }
}

unsafe extern "C" fn telemetry_enter_trampoline(
    user_data: *mut c_void,
    scope_name: *const u8,
    scope_name_len: usize,
    call_id: *const u8,
    call_id_len: usize,
) -> *mut c_void {
    if user_data.is_null() {
        return ptr::null_mut();
    }
    // SAFETY: state is retained globally until ai_telemetry_clear returns.
    let state = unsafe { &*user_data.cast::<TelemetryState>() };
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: telemetry byte views are valid for this invocation.
        let scope = String::from_utf8_lossy(unsafe {
            raw_slice(scope_name, scope_name_len).unwrap_or_default()
        });
        // SAFETY: telemetry byte views are valid for this invocation.
        let call =
            String::from_utf8_lossy(unsafe { raw_slice(call_id, call_id_len).unwrap_or_default() });
        let value = state
            .callbacks
            .enter
            .as_ref()
            .map_or(0, |callback| callback(&scope, &call));
        if state.callbacks.exit.is_none() {
            return 0;
        }
        let mut token_id = state.next_token.fetch_add(1, Ordering::Relaxed);
        if token_id == 0 {
            token_id = state.next_token.fetch_add(1, Ordering::Relaxed);
        }
        lock(&state.tokens).insert(token_id, value);
        token_id
    }));
    match outcome {
        Ok(0) => ptr::null_mut(),
        Ok(token_id) => token_id as *mut c_void,
        Err(payload) => {
            lock(&state.failures).push(panic_message(&payload));
            ptr::null_mut()
        }
    }
}

unsafe extern "C" fn telemetry_exit_trampoline(
    user_data: *mut c_void,
    scope_name: *const u8,
    scope_name_len: usize,
    token: *mut c_void,
) {
    if user_data.is_null() {
        return;
    }
    // SAFETY: state is retained globally until ai_telemetry_clear returns.
    let state = unsafe { &*user_data.cast::<TelemetryState>() };
    let token = if token.is_null() {
        None
    } else {
        lock(&state.tokens).remove(&(token as usize))
    };
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: telemetry byte view is valid for this invocation.
        let scope = String::from_utf8_lossy(unsafe {
            raw_slice(scope_name, scope_name_len).unwrap_or_default()
        });
        if let Some(callback) = &state.callbacks.exit {
            callback(&scope, token);
        }
    }));
    if let Err(payload) = outcome {
        lock(&state.failures).push(panic_message(&payload));
    }
}

/// Logical telemetry registration. Drop unregisters but keeps callback state
/// alive in the process registry until [`clear_telemetry`].
pub struct TelemetryRegistration {
    entry: Arc<TelemetryEntry>,
}

impl TelemetryRegistration {
    #[must_use]
    pub fn is_active(&self) -> bool {
        !self.entry.handle.load(Ordering::Acquire).is_null()
    }

    #[must_use]
    pub fn callback_failures(&self) -> Vec<String> {
        lock(&self.entry.state.failures).clone()
    }

    /// Performs the thread-safe logical disable. In-flight callbacks may finish.
    pub fn unregister(&self) {
        let _registry = lock(telemetry_registry());
        let handle = self.entry.handle.swap(ptr::null_mut(), Ordering::AcqRel);
        if !handle.is_null() {
            // SAFETY: swap ensures this registration is unregistered once.
            unsafe { sys::ai_telemetry_unregister(handle) };
        }
    }
}

impl Drop for TelemetryRegistration {
    fn drop(&mut self) {
        self.unregister();
    }
}

/// Clears all C and Rust telemetry registrations process-wide.
///
/// Call only after telemetry-producing operations and copied dispatchers have
/// quiesced; the ABI forbids racing this with register/unregister.
pub fn clear_telemetry() {
    let mut registry = lock(telemetry_registry());
    // SAFETY: serialization is enforced for Rust callers; quiescence is the
    // documented application-level precondition shared with the C API.
    unsafe { sys::ai_telemetry_clear() };
    for entry in registry.iter() {
        entry.handle.store(ptr::null_mut(), Ordering::Release);
        lock(&entry.state.tokens).clear();
    }
    registry.clear();
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn part_type_preserves_unknown_values() {
        assert_eq!(PartType::from_raw(10_000), PartType::Unknown(10_000));
    }

    #[test]
    fn runtime_config_defaults_to_zig_limits() {
        assert_eq!(RuntimeConfig::default().async_limit, 0);
        assert_eq!(RuntimeConfig::default().concurrent_limit, 0);
    }
}
