use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let zig_project_dir = manifest_dir.join("../..");
    let zig_lib_dir = zig_project_dir.join("zig-out/lib");
    let lib_path = zig_lib_dir.join("libawp_zig.a");
    let obj_path = zig_lib_dir.join("awp_zig.o");

    std::fs::create_dir_all(&zig_lib_dir).unwrap();

    // Rebuild static library with explicit output path
    let obj_status = Command::new("zig")
        .current_dir(&zig_project_dir)
        .args([
            "build-obj",
            "src/root.zig",
            "-O",
            "ReleaseFast",
            "-lc",
            &format!("-femit-bin={}", obj_path.display()),
        ])
        .status()
        .expect("Failed to execute zig build-obj");

    if !obj_status.success() {
        panic!("zig build-obj failed");
    }

    let ar_status = Command::new("ar")
        .current_dir(&zig_project_dir)
        .args([
            "rcs",
            lib_path.to_str().unwrap(),
            obj_path.to_str().unwrap(),
        ])
        .status()
        .expect("Failed to execute ar");

    if !ar_status.success() {
        panic!("ar rcs failed");
    }

    let _ = std::fs::remove_file(obj_path);

    println!("cargo:rustc-link-search=native={}", zig_lib_dir.display());
    println!("cargo:rustc-link-lib=static=awp_zig");
    println!("cargo:rerun-if-changed=../../src/root.zig");
    println!("cargo:rerun-if-changed=../../src/c_abi.zig");
    println!("cargo:rerun-if-changed=../../src/types.zig");
}
