package saber

import win "core:sys/windows"

// WGL side of retro_hw.odin: the core's GL context, sharing objects with raylib's.

Hw_Gl :: struct {
	hdc:      win.HDC,
	main_ctx: win.HGLRC, // raylib's
	core_ctx: win.HGLRC,
	opengl32: win.HMODULE,
}

hw_gl_set_proc_address :: win.gl_set_proc_address

hw_gl_proc_address :: proc "contextless" (g: ^Hw_Gl, sym: cstring) -> rawptr {
	p := win.wglGetProcAddress(sym)
	switch uintptr(p) {
	case 0, 1, 2, 3, ~uintptr(0):
		p = win.GetProcAddress(g.opengl32, sym)
	}
	return p
}

// Brings the Vulkan driver up once, before any GL context exists. Some AMD OpenGL drivers
// (seen with 27.20.14044 on a Radeon + GeForce laptop) break every live GL context the
// first time Vulkan initialises in the process, and PPSSPP probes Vulkan while starting,
// which crashed Saber in atio6axx.dll. Once warmed up here, later probes are harmless.
// Call before InitWindow.
hw_gl_prepare_driver :: proc() {
	Instance_Create_Info :: struct {
		s_type:                           i32, // VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO = 1
		next:                             rawptr,
		flags:                            u32,
		application_info:                 rawptr,
		enabled_layer_count:              u32,
		enabled_layer_names:              rawptr,
		enabled_extension_count:          u32,
		enabled_extension_names:          rawptr,
	}
	Get_Instance_Proc :: proc "system" (instance: rawptr, name: cstring) -> rawptr
	Create_Instance :: proc "system" (info: ^Instance_Create_Info, alloc: rawptr, instance: ^rawptr) -> i32
	Enumerate_Devices :: proc "system" (instance: rawptr, count: ^u32, devices: rawptr) -> i32
	Destroy_Instance :: proc "system" (instance: rawptr, alloc: rawptr)

	lib := win.LoadLibraryW(win.L("vulkan-1.dll"))
	if lib == nil do return // no Vulkan driver: nothing to warm up
	defer win.FreeLibrary(lib)
	get_proc := Get_Instance_Proc(win.GetProcAddress(lib, "vkGetInstanceProcAddr"))
	if get_proc == nil do return
	create := Create_Instance(get_proc(nil, "vkCreateInstance"))
	if create == nil do return
	info := Instance_Create_Info{s_type = 1}
	instance: rawptr
	if create(&info, nil, &instance) != 0 || instance == nil do return
	if enumerate := Enumerate_Devices(get_proc(instance, "vkEnumeratePhysicalDevices")); enumerate != nil {
		n: u32
		enumerate(instance, &n, nil)
	}
	if destroy := Destroy_Instance(get_proc(instance, "vkDestroyInstance")); destroy != nil do destroy(instance, nil)
}

// Remembers raylib's (current) context.
hw_gl_bind_main :: proc(g: ^Hw_Gl) -> bool {
	g.hdc = win.wglGetCurrentDC()
	g.main_ctx = win.wglGetCurrentContext()
	if g.hdc == nil || g.main_ctx == nil do return false
	g.opengl32 = win.LoadLibraryW(win.L("opengl32.dll"))
	if win.wglCreateContextAttribsARB == nil {
		win.wglCreateContextAttribsARB = auto_cast win.wglGetProcAddress("wglCreateContextAttribsARB")
	}
	return win.wglCreateContextAttribsARB != nil
}

hw_gl_create :: proc(g: ^Hw_Gl, major, minor: i32, core: bool) -> bool {
	profile: i32 = core ? win.WGL_CONTEXT_CORE_PROFILE_BIT_ARB : win.WGL_CONTEXT_COMPATIBILITY_PROFILE_BIT_ARB
	attribs := [?]i32 {
		win.WGL_CONTEXT_MAJOR_VERSION_ARB, major,
		win.WGL_CONTEXT_MINOR_VERSION_ARB, minor,
		win.WGL_CONTEXT_PROFILE_MASK_ARB, profile,
		0,
	}
	g.core_ctx = win.wglCreateContextAttribsARB(g.hdc, rawptr(g.main_ctx), &attribs[0])
	return g.core_ctx != nil
}

hw_gl_use_core :: proc(g: ^Hw_Gl) {
	win.wglMakeCurrent(g.hdc, g.core_ctx)
}

hw_gl_use_main :: proc(g: ^Hw_Gl) {
	win.wglMakeCurrent(g.hdc, g.main_ctx)
}

// Call with raylib's context current.
hw_gl_destroy :: proc(g: ^Hw_Gl) {
	if g.core_ctx != nil do win.wglDeleteContext(g.core_ctx)
	if g.opengl32 != nil do win.FreeLibrary(g.opengl32)
	g^ = {}
}
