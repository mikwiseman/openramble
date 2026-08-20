fn main() {
    // ggml's Metal sources use Clang's macOS availability helper. Rust links
    // with `-nodefaultlibs`, so the C driver does not add compiler-rt for us and
    // a release binary otherwise fails with an undefined
    // `__isPlatformVersionAtLeast`. Resolve the active Xcode toolchain rather
    // than baking one machine's Xcode path into the repository; the archive is
    // universal and supplies both Intel and Apple Silicon slices.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        let output = std::process::Command::new("xcrun")
            .args(["clang", "-print-resource-dir"])
            .output()
            .expect("xcrun could not locate Clang's runtime");
        assert!(
            output.status.success(),
            "xcrun could not locate Clang's runtime"
        );
        let resource = String::from_utf8(output.stdout).expect("Clang resource path was not UTF-8");
        println!(
            "cargo:rustc-link-search=native={}/lib/darwin",
            resource.trim()
        );
        println!("cargo:rustc-link-lib=static=clang_rt.osx");
    }
    tauri_build::build()
}
