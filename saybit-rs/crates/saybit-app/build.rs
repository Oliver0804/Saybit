fn main() {
    // Linux：SenseVoice 走動態 libsherpa-onnx-c-api.so / libonnxruntime.so（sherpa-rs-sys 複製到 target/<profile>/）。
    // 執行檔要能在這些位置找到它們：
    //   $ORIGIN                 cargo run / target/release 旁邊
    //   $ORIGIN/../lib/saybit   cargo-packager 的 deb / AppImage：binary 在 usr/bin，resources 在 usr/lib/saybit
    //   $ORIGIN/lib             備援
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("linux") {
        for path in ["$ORIGIN", "$ORIGIN/../lib/saybit", "$ORIGIN/lib"] {
            println!("cargo:rustc-link-arg-bins=-Wl,-rpath,{path}");
        }
    }
    println!("cargo:rerun-if-changed=build.rs");
}
