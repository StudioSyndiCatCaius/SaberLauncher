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
