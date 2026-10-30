package saber

// Platform contract. Each target provides these from its *_<os>.odin files;
// Odin has no prototypes, so a missing one shows up as an undefined symbol.
// Keep signatures identical across platforms.
//
// Types:
//   Disc_Handle, Proc_Info, Proc_Handle, Window_Handle
//
// platform_<os>.odin
//   quote_arg(s: string) -> string
//   exe_command(exe_path, args: string) -> string
//   bat_command(bat_path: string) -> string
//   open_steam_big_picture()
//   sleep_ms(ms: u32)
//   single_instance() -> bool
//   load_snprintf() -> Snprintf_Proc
//   core_file_name(name: string) -> string
//   SYSTEM_CORE_DIRS :: []string
//   updater_path() -> string
//   run_hidden_wait(exe, args: string) -> (code: u32, ok: bool)
//   start_updater(args: string) -> bool
//   restart_self() -> bool
//
// disc_<os>.odin
//   disc_open(letter: u8) -> (Disc_Handle, bool)
//   disc_close(h: Disc_Handle)
//   disc_last_error() -> int
//   disc_read_toc_raw(h: Disc_Handle, raw: []u8) -> bool
//   disc_read_full_toc_raw(h: Disc_Handle, raw: []u8) -> (got: int, ok: bool)
//   disc_read_user(h: Disc_Handle, lba: int, buf: []u8) -> bool
//   disc_read_raw(h: Disc_Handle, lba, n: int, mode: u32, dst: []u8) -> bool
//   disc_profile(h: Disc_Handle) -> u16
//
// drives_<os>.odin
//   current_drive_mask() -> u32
//   is_system_drive(letter: rune) -> bool
//   drive_type(letter: rune) -> u32
//   drive_root(letter: rune) -> string
//   drive_path(letter: rune, parts: ..string) -> string
//   volume_label(letter: rune) -> string
//   volume_serial(letter: u8) -> (serial: u32, present: bool)
//
// hwgl_<os>.odin
//   Hw_Gl :: struct
//   hw_gl_proc_address "contextless" (g: ^Hw_Gl, sym: cstring) -> rawptr
//   hw_gl_bind_main(g: ^Hw_Gl) -> bool
//   hw_gl_create(g: ^Hw_Gl, major, minor: i32, core: bool) -> bool
//   hw_gl_use_core(g: ^Hw_Gl)
//   hw_gl_use_main(g: ^Hw_Gl)
//   hw_gl_destroy(g: ^Hw_Gl)
//
// movies_<os>.odin
//   extract_thumb_shell(video_path, dest_png: string) -> bool
//   find_ffmpeg_exe() -> (string, bool)
//   run_hidden_process(exe, cmd: string, timeout_ms: u32) -> bool
//   movie_player() -> (exe, args_prefix, name: string, ok: bool)
//
// online_<os>.odin
//   http_fetch(r: ^Http_Request, body: ^[dynamic]u8) -> bool
//
// session_<os>.odin
//   proc_handle(pi: Proc_Info) -> Proc_Handle
//   proc_pid(pi: Proc_Info) -> u32
//   proc_release(pi: Proc_Info)
//   proc_alive(h: Proc_Handle) -> bool
//   Proc_Row :: struct
//   snapshot_processes(rows: []Proc_Row, match_name: string) -> int
//   session_close(s: ^Session)
//   session_kill(s: ^Session)
//   xinput_init()
//   xinput_guide_down() -> bool
//   capture_screen() -> (rl.Texture2D, bool)
//
// settings_<os>.odin
//   exe_full_path() -> string
//   detect_launch_mode() -> Launch_Mode
//   is_acting_as_shell() -> bool
//   apply_launch_mode(mode: Launch_Mode) -> (ok: bool, err: string)
//   system_logoff() -> bool
//   system_restart() -> bool
//   system_shutdown() -> bool
//   open_desktop()
//
// window_<os>.odin
//   foreground_window() -> Window_Handle
//   window_pid(hwnd: Window_Handle) -> u32
//   allow_foreground()
//   hide_for_child()
//   show_window_on_top(topmost: bool)
//   restore_after_child()
//   keep_fullscreen()
