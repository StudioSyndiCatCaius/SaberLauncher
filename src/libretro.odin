package saber

// Minimal libretro.h bindings (only what Saber uses; shared with SimpRetro).

import "core:c"
import "core:dynlib"

RETRO_API_VERSION :: 1

RETRO_DEVICE_TYPE_SHIFT :: 8
RETRO_DEVICE_MASK       :: (1 << RETRO_DEVICE_TYPE_SHIFT) - 1
RETRO_DEVICE_NONE       :: 0
RETRO_DEVICE_JOYPAD     :: 1
RETRO_DEVICE_ANALOG     :: 5

RETRO_DEVICE_ID_JOYPAD_B      :: 0
RETRO_DEVICE_ID_JOYPAD_Y      :: 1
RETRO_DEVICE_ID_JOYPAD_SELECT :: 2
RETRO_DEVICE_ID_JOYPAD_START  :: 3
RETRO_DEVICE_ID_JOYPAD_UP     :: 4
RETRO_DEVICE_ID_JOYPAD_DOWN   :: 5
RETRO_DEVICE_ID_JOYPAD_LEFT   :: 6
RETRO_DEVICE_ID_JOYPAD_RIGHT  :: 7
RETRO_DEVICE_ID_JOYPAD_A      :: 8
RETRO_DEVICE_ID_JOYPAD_X      :: 9
RETRO_DEVICE_ID_JOYPAD_L      :: 10
RETRO_DEVICE_ID_JOYPAD_R      :: 11
RETRO_DEVICE_ID_JOYPAD_L2     :: 12
RETRO_DEVICE_ID_JOYPAD_R2     :: 13
RETRO_DEVICE_ID_JOYPAD_L3     :: 14
RETRO_DEVICE_ID_JOYPAD_R3     :: 15
RETRO_DEVICE_ID_JOYPAD_MASK   :: 256

RETRO_DEVICE_INDEX_ANALOG_LEFT   :: 0
RETRO_DEVICE_INDEX_ANALOG_RIGHT  :: 1
RETRO_DEVICE_INDEX_ANALOG_BUTTON :: 2
RETRO_DEVICE_ID_ANALOG_X         :: 0
RETRO_DEVICE_ID_ANALOG_Y         :: 1

RETRO_MEMORY_SAVE_RAM :: 0
RETRO_MEMORY_RTC      :: 1

RETRO_ENVIRONMENT_EXPERIMENTAL :: 0x10000

// Environment commands
ENV_SET_ROTATION                          :: 1
ENV_GET_OVERSCAN                          :: 2
ENV_GET_CAN_DUPE                          :: 3
ENV_SET_MESSAGE                           :: 6
ENV_SHUTDOWN                              :: 7
ENV_SET_PERFORMANCE_LEVEL                 :: 8
ENV_GET_SYSTEM_DIRECTORY                  :: 9
ENV_SET_PIXEL_FORMAT                      :: 10
ENV_SET_INPUT_DESCRIPTORS                 :: 11
ENV_SET_KEYBOARD_CALLBACK                 :: 12
ENV_SET_DISK_CONTROL_INTERFACE            :: 13
ENV_SET_HW_RENDER                         :: 14
ENV_GET_VARIABLE                          :: 15
ENV_SET_VARIABLES                         :: 16
ENV_GET_VARIABLE_UPDATE                   :: 17
ENV_SET_SUPPORT_NO_GAME                   :: 18
ENV_GET_LIBRETRO_PATH                     :: 19
ENV_SET_FRAME_TIME_CALLBACK               :: 21
ENV_SET_AUDIO_CALLBACK                    :: 22
ENV_GET_RUMBLE_INTERFACE                  :: 23
ENV_GET_INPUT_DEVICE_CAPABILITIES         :: 24
ENV_GET_LOG_INTERFACE                     :: 27
ENV_GET_PERF_INTERFACE                    :: 28
ENV_GET_CORE_ASSETS_DIRECTORY             :: 30
ENV_GET_SAVE_DIRECTORY                    :: 31
ENV_SET_SYSTEM_AV_INFO                    :: 32
ENV_SET_PROC_ADDRESS_CALLBACK             :: 33
ENV_SET_SUBSYSTEM_INFO                    :: 34
ENV_SET_CONTROLLER_INFO                   :: 35
ENV_SET_MEMORY_MAPS                       :: 36 | RETRO_ENVIRONMENT_EXPERIMENTAL
ENV_SET_GEOMETRY                          :: 37
ENV_GET_USERNAME                          :: 38
ENV_GET_LANGUAGE                          :: 39
ENV_SET_SUPPORT_ACHIEVEMENTS              :: 42 | RETRO_ENVIRONMENT_EXPERIMENTAL
ENV_SET_SERIALIZATION_QUIRKS              :: 44
ENV_SET_HW_SHARED_CONTEXT                 :: 44 | RETRO_ENVIRONMENT_EXPERIMENTAL
ENV_GET_AUDIO_VIDEO_ENABLE                :: 47 | RETRO_ENVIRONMENT_EXPERIMENTAL
ENV_GET_FASTFORWARDING                    :: 49 | RETRO_ENVIRONMENT_EXPERIMENTAL
ENV_GET_TARGET_REFRESH_RATE               :: 50 | RETRO_ENVIRONMENT_EXPERIMENTAL
ENV_GET_INPUT_BITMASKS                    :: 51 | RETRO_ENVIRONMENT_EXPERIMENTAL
ENV_GET_CORE_OPTIONS_VERSION              :: 52
ENV_SET_CORE_OPTIONS_DISPLAY              :: 55
ENV_GET_PREFERRED_HW_RENDER               :: 56
ENV_GET_DISK_CONTROL_INTERFACE_VERSION    :: 57
ENV_SET_DISK_CONTROL_EXT_INTERFACE        :: 58
ENV_GET_MESSAGE_INTERFACE_VERSION         :: 59
ENV_SET_MESSAGE_EXT                       :: 60
ENV_GET_INPUT_MAX_USERS                   :: 61
ENV_SET_CONTENT_INFO_OVERRIDE             :: 65
ENV_SET_CORE_OPTIONS_UPDATE_DISPLAY_CB    :: 69
ENV_SET_VARIABLE                          :: 70
ENV_GET_THROTTLE_STATE                    :: 71 | RETRO_ENVIRONMENT_EXPERIMENTAL
ENV_GET_SAVESTATE_CONTEXT                 :: 72 | RETRO_ENVIRONMENT_EXPERIMENTAL
ENV_GET_JIT_CAPABLE                       :: 74

Pixel_Format :: enum c.int {
	RGB1555  = 0,
	XRGB8888 = 1,
	RGB565   = 2,
}

HW_Context_Type :: enum c.int {
	NONE             = 0,
	OPENGL           = 1,
	OPENGLES2        = 2,
	OPENGL_CORE      = 3,
	OPENGLES3        = 4,
	OPENGLES_VERSION = 5,
	VULKAN           = 6,
	D3D11            = 7,
	D3D10            = 8,
	D3D12            = 9,
	D3D9             = 10,
}

RETRO_HW_FRAME_BUFFER_VALID :: rawptr(~uintptr(0))

HW_Context_Reset_Proc  :: #type proc "c" ()
HW_Get_FB_Proc         :: #type proc "c" () -> uintptr
HW_Get_Proc_Addr_Proc  :: #type proc "c" (sym: cstring) -> rawptr

HW_Render_Callback :: struct {
	context_type:            HW_Context_Type,
	context_reset:           HW_Context_Reset_Proc,
	get_current_framebuffer: HW_Get_FB_Proc,
	get_proc_address:        HW_Get_Proc_Addr_Proc,
	depth:                   bool,
	stencil:                 bool,
	bottom_left_origin:      bool,
	version_major:           c.uint,
	version_minor:           c.uint,
	cache_context:           bool,
	context_destroy:         HW_Context_Reset_Proc,
	debug_context:           bool,
}

System_Info :: struct {
	library_name:     cstring,
	library_version:  cstring,
	valid_extensions: cstring,
	need_fullpath:    bool,
	block_extract:    bool,
}

Game_Geometry :: struct {
	base_width:   c.uint,
	base_height:  c.uint,
	max_width:    c.uint,
	max_height:   c.uint,
	aspect_ratio: f32,
}

System_Timing :: struct {
	fps:         f64,
	sample_rate: f64,
}

System_AV_Info :: struct {
	geometry: Game_Geometry,
	timing:   System_Timing,
}

Game_Info :: struct {
	path: cstring,
	data: rawptr,
	size: c.size_t,
	meta: cstring,
}

Retro_Variable :: struct {
	key:   cstring,
	value: cstring,
}

Retro_Message :: struct {
	msg:    cstring,
	frames: c.uint,
}

Retro_Message_Ext :: struct {
	msg:      cstring,
	duration: c.uint,
	priority: c.uint,
	level:    c.int,
	target:   c.int,
	type:     c.int,
	progress: i8,
}

Frame_Time_Callback :: struct {
	callback:  proc "c" (usec: i64),
	reference: i64,
}

Rumble_Interface :: struct {
	set_rumble_state: proc "c" (port: c.uint, effect: c.int, strength: u16) -> bool,
}

Perf_Counter :: struct {
	ident:      cstring,
	start:      u64,
	total:      u64,
	call_cnt:   u64,
	registered: bool,
}

Perf_Callback :: struct {
	get_time_usec:    proc "c" () -> i64,
	get_cpu_features: proc "c" () -> u64,
	get_perf_counter: proc "c" () -> u64,
	perf_register:    proc "c" (counter: ^Perf_Counter),
	perf_start:       proc "c" (counter: ^Perf_Counter),
	perf_stop:        proc "c" (counter: ^Perf_Counter),
	perf_log:         proc "c" (),
}

// The real signature is variadic: void (*)(enum retro_log_level, const char *fmt, ...).
// On the Win64 ABI the caller cleans up the stack and variadic arguments are
// passed exactly like fixed ones, so a callee that only reads the first two
// arguments is safe.
Log_Callback :: struct {
	log: proc "c" (level: c.int, fmt: cstring),
}

Controller_Description :: struct {
	desc: cstring,
	id:   c.uint,
}

Controller_Info :: struct {
	types:     rawptr,
	num_types: c.uint,
}

Throttle_State :: struct {
	mode: c.uint,
	rate: f32,
}

// Covers both retro_disk_control_callback and retro_disk_control_ext_callback;
// the ext fields are only valid when the core used the EXT interface.
Disk_Control :: struct {
	set_eject_state:     proc "c" (ejected: bool) -> bool,
	get_eject_state:     proc "c" () -> bool,
	get_image_index:     proc "c" () -> c.uint,
	set_image_index:     proc "c" (index: c.uint) -> bool,
	get_num_images:      proc "c" () -> c.uint,
	replace_image_index: proc "c" (index: c.uint, info: ^Game_Info) -> bool,
	add_image_index:     proc "c" () -> bool,
	set_initial_image:   proc "c" (index: c.uint, path: cstring) -> bool,
	get_image_path:      proc "c" (index: c.uint, path: [^]u8, len: c.size_t) -> bool,
	get_image_label:     proc "c" (index: c.uint, label: [^]u8, len: c.size_t) -> bool,
}

Environment_Proc        :: #type proc "c" (cmd: c.uint, data: rawptr) -> bool
Video_Refresh_Proc      :: #type proc "c" (data: rawptr, width, height: c.uint, pitch: c.size_t)
Audio_Sample_Proc       :: #type proc "c" (left, right: i16)
Audio_Sample_Batch_Proc :: #type proc "c" (data: [^]i16, frames: c.size_t) -> c.size_t
Input_Poll_Proc         :: #type proc "c" ()
Input_State_Proc        :: #type proc "c" (port, device, index, id: c.uint) -> i16

// Loaded with dynlib.initialize_symbols using the "retro_" prefix.
Core_API :: struct {
	set_environment:            proc "c" (cb: Environment_Proc),
	set_video_refresh:          proc "c" (cb: Video_Refresh_Proc),
	set_audio_sample:           proc "c" (cb: Audio_Sample_Proc),
	set_audio_sample_batch:     proc "c" (cb: Audio_Sample_Batch_Proc),
	set_input_poll:             proc "c" (cb: Input_Poll_Proc),
	set_input_state:            proc "c" (cb: Input_State_Proc),
	init:                       proc "c" (),
	deinit:                     proc "c" (),
	api_version:                proc "c" () -> c.uint,
	get_system_info:            proc "c" (info: ^System_Info),
	get_system_av_info:         proc "c" (info: ^System_AV_Info),
	set_controller_port_device: proc "c" (port, device: c.uint),
	reset:                      proc "c" (),
	run:                        proc "c" (),
	serialize_size:             proc "c" () -> c.size_t,
	serialize:                  proc "c" (data: rawptr, size: c.size_t) -> bool,
	unserialize:                proc "c" (data: rawptr, size: c.size_t) -> bool,
	load_game:                  proc "c" (game: ^Game_Info) -> bool,
	unload_game:                proc "c" (),
	get_memory_data:            proc "c" (id: c.uint) -> rawptr,
	get_memory_size:            proc "c" (id: c.uint) -> c.size_t,
	__handle:                   dynlib.Library,
}

// ---------------------------------------------------------------------------
// VFS (retro_vfs_interface, v3). Lets Saber serve files that don't exist on disk,
// e.g. a physical CD exposed as a virtual .cue/.bin.

ENV_GET_VFS_INTERFACE :: 45 | RETRO_ENVIRONMENT_EXPERIMENTAL
ENV_GET_CURRENT_SOFTWARE_FRAMEBUFFER :: 40 | RETRO_ENVIRONMENT_EXPERIMENTAL

VFS_FILE_ACCESS_READ            :: 1 << 0
VFS_FILE_ACCESS_WRITE           :: 1 << 1
VFS_FILE_ACCESS_UPDATE_EXISTING :: 1 << 2

VFS_SEEK_POSITION_START   :: 0
VFS_SEEK_POSITION_CURRENT :: 1
VFS_SEEK_POSITION_END     :: 2

VFS_STAT_IS_VALID     :: 1 << 0
VFS_STAT_IS_DIRECTORY :: 1 << 1

Vfs_Interface :: struct {
	// v1
	get_path:        proc "c" (stream: rawptr) -> cstring,
	open:            proc "c" (path: cstring, mode: c.uint, hints: c.uint) -> rawptr,
	close:           proc "c" (stream: rawptr) -> c.int,
	size:            proc "c" (stream: rawptr) -> i64,
	tell:            proc "c" (stream: rawptr) -> i64,
	seek:            proc "c" (stream: rawptr, offset: i64, seek_position: c.int) -> i64,
	read:            proc "c" (stream: rawptr, s: rawptr, len: u64) -> i64,
	write:           proc "c" (stream: rawptr, s: rawptr, len: u64) -> i64,
	flush:           proc "c" (stream: rawptr) -> c.int,
	remove:          proc "c" (path: cstring) -> c.int,
	rename:          proc "c" (old_path, new_path: cstring) -> c.int,
	// v2
	truncate:        proc "c" (stream: rawptr, length: i64) -> i64,
	// v3
	stat:            proc "c" (path: cstring, size: ^i32) -> c.int,
	mkdir:           proc "c" (dir: cstring) -> c.int,
	opendir:         proc "c" (dir: cstring, include_hidden: bool) -> rawptr,
	readdir:         proc "c" (dirstream: rawptr) -> bool,
	dirent_get_name: proc "c" (dirstream: rawptr) -> cstring,
	dirent_is_dir:   proc "c" (dirstream: rawptr) -> bool,
	closedir:        proc "c" (dirstream: rawptr) -> c.int,
}

Vfs_Interface_Info :: struct {
	required_interface_version: u32,
	iface:                      ^Vfs_Interface,
}
