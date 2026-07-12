use std::env;
use std::path::PathBuf;

fn main() {
    println!("cargo:rerun-if-env-changed=AI_ZIG_LIB_DIR");
    println!("cargo:rerun-if-env-changed=AI_ZIG_LINK_STATIC");

    let lib_dir = env::var_os("AI_ZIG_LIB_DIR").map_or_else(
        || {
            PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").expect("manifest directory"))
                .join("../../..")
                .join("zig-out/lib")
        },
        PathBuf::from,
    );
    println!("cargo:rustc-link-search=native={}", lib_dir.display());

    // Static is the checkout-friendly default: `cargo test` and examples do
    // not need a platform-specific runtime loader path. Set the variable to
    // `0` for the versioned shared library.
    let link_static = env::var_os("AI_ZIG_LINK_STATIC").is_none_or(|value| value != "0");
    if link_static {
        println!("cargo:rustc-link-lib=static=ai");
    } else {
        println!("cargo:rustc-link-lib=dylib=ai");

        let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
        if matches!(target_os.as_str(), "linux" | "macos") {
            println!("cargo:rustc-link-arg=-Wl,-rpath,{}", lib_dir.display());
        }
    }
}
