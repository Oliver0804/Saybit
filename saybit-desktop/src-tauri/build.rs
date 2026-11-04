fn main() {
    // Linux 的 SenseVoice 動態連結 libsherpa-onnx-c-api.so（它自己的 RUNPATH 是 $ORIGIN，
    // 會在同目錄找 libonnxruntime.so）。執行檔要能找到它：
    //   $ORIGIN                          開發時，sherpa-rs-sys 把 .so 複製到 target/<profile>/
    //   $ORIGIN/../lib/saybit-desktop    deb / rpm / AppImage：執行檔在 usr/bin，.so 由
    //                                    tauri.linux.conf.json 的 files 放到 usr/lib/saybit-desktop
    //   $ORIGIN/lib                      保險用
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("linux") {
        for path in ["$ORIGIN", "$ORIGIN/../lib/saybit-desktop", "$ORIGIN/lib"] {
            println!("cargo:rustc-link-arg=-Wl,-rpath,{path}");
        }
    }
    tauri_build::build()
}
