#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
  if std::env::args().any(|arg| arg == "--install-components") {
    std::process::exit(dsharness_lib::install_components_cli());
  }
  dsharness_lib::run()
}
