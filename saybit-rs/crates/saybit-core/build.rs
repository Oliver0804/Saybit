fn main() {
    // Linux 的 SenseVoice 動態連結 libsherpa-onnx-c-api.so（它自己的 RUNPATH 是 $ORIGIN，
    // 會在同目錄找 libonnxruntime.so）。sherpa-rs-sys 把 .so 複製到 target/<profile>/。
    //   $ORIGIN/..  本 crate 的測試執行檔在 target/<profile>/deps/
    //   $ORIGIN     同目錄
    // 注意：rustc-link-arg 只作用在「本 package」的 bin / test / example；saybit-app 的執行檔
    // 需要在它自己的 build.rs 加 $ORIGIN 與打包位置（例如 $ORIGIN/../lib/saybit）的 rpath。
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("linux") {
        for path in ["$ORIGIN", "$ORIGIN/..", "$ORIGIN/lib"] {
            println!("cargo:rustc-link-arg=-Wl,-rpath,{path}");
        }
    }
    println!("cargo:rerun-if-changed=build.rs");
}
