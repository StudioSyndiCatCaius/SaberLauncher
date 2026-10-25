package saber

// Hardware-rendered cores (PSP, PS2...), ported from SimpRetro. The core gets its own
// OpenGL context sharing objects with raylib's, so neither side tramples the other's
// cached GL state; it draws into an FBO whose colour texture raylib then presents.
// The core's context is current only while it runs (context_reset / retro_run / destroy).

import gl "vendor:OpenGL"
import rl "vendor:raylib"
import win "core:sys/windows"

Retro_Hw :: struct {
	enabled:  bool,
	cb:       HW_Render_Callback,
	ready:    bool,
	hdc:      win.HDC,
	main_ctx: win.HGLRC, // raylib's
	core_ctx: win.HGLRC,
	opengl32: win.HMODULE,
	fbo:      u32,      // lives in the core's context (FBOs aren't shared)
	rb:       u32,
	tex:      u32,      // shared colour texture
	w, h:     i32,
	frame:    bool,     // the core presented a frame (RETRO_HW_FRAME_BUFFER_VALID)
	depth:    int,      // nested retro_hw_begin calls (e.g. SET_SYSTEM_AV_INFO from inside retro_run)
}

rhw: Retro_Hw

// ENV_SET_HW_RENDER
retro_hw_request :: proc(cb: ^HW_Render_Callback) -> bool {
	#partial switch cb.context_type {
	case .OPENGL, .OPENGL_CORE:
	case:
		return false
	}
	cb.get_current_framebuffer = retro_hw_get_framebuffer
	cb.get_proc_address = retro_hw_get_proc_address
	rhw.cb = cb^
	rhw.enabled = true
	return true
}

retro_hw_get_framebuffer :: proc "c" () -> uintptr {
	return uintptr(rhw.fbo)
}

retro_hw_get_proc_address :: proc "c" (sym: cstring) -> rawptr {
	p := win.wglGetProcAddress(sym)
	switch uintptr(p) {
	case 0, 1, 2, 3, ~uintptr(0):
		p = win.GetProcAddress(rhw.opengl32, sym)
	}
	return p
}

// After load_game: creates the core's context + framebuffer and calls context_reset.
retro_hw_start :: proc(max_w, max_h: i32) -> bool {
	if !rhw.enabled do return true
	rhw.hdc = win.wglGetCurrentDC()
	rhw.main_ctx = win.wglGetCurrentContext()
	if rhw.hdc == nil || rhw.main_ctx == nil do return false
	rhw.opengl32 = win.LoadLibraryW(win.L("opengl32.dll"))
	if win.wglCreateContextAttribsARB == nil {
		win.wglCreateContextAttribsARB = auto_cast win.wglGetProcAddress("wglCreateContextAttribsARB")
	}
	if win.wglCreateContextAttribsARB == nil do return false

	core := rhw.cb.context_type == .OPENGL_CORE
	profile: i32 = core ? win.WGL_CONTEXT_CORE_PROFILE_BIT_ARB : win.WGL_CONTEXT_COMPATIBILITY_PROFILE_BIT_ARB
	versions := [?][2]i32{{4, 6}, {4, 5}, {4, 4}, {4, 3}, {4, 2}, {4, 1}, {4, 0}, {3, 3}, {3, 2}}
	for v in versions {
		if core && (v[0] < i32(rhw.cb.version_major) || (v[0] == i32(rhw.cb.version_major) && v[1] < i32(rhw.cb.version_minor))) do continue
		attribs := [?]i32 {
			win.WGL_CONTEXT_MAJOR_VERSION_ARB, v[0],
			win.WGL_CONTEXT_MINOR_VERSION_ARB, v[1],
			win.WGL_CONTEXT_PROFILE_MASK_ARB, profile,
			0,
		}
		rhw.core_ctx = win.wglCreateContextAttribsARB(rhw.hdc, rawptr(rhw.main_ctx), &attribs[0])
		if rhw.core_ctx != nil {
			retro_log_line("[hw] core GL context %d.%d %s", v[0], v[1], core ? "core" : "compat")
			break
		}
	}
	if rhw.core_ctx == nil do return false

	// GL entry points of the core's context (the same driver serves raylib's)
	win.wglMakeCurrent(rhw.hdc, rhw.core_ctx)
	gl.load_up_to(4, 6, win.gl_set_proc_address)
	rhw.ready = true
	retro_hw_resize(max_w, max_h)
	if rhw.cb.context_reset != nil do rhw.cb.context_reset()
	win.wglMakeCurrent(rhw.hdc, rhw.main_ctx)
	return true
}

// (Re)allocates the framebuffer; call with the core's context current.
retro_hw_resize :: proc(max_w, max_h: i32) {
	w, h := max(max_w, 1), max(max_h, 1)
	if rhw.fbo == 0 {
		gl.GenFramebuffers(1, &rhw.fbo)
		gl.GenTextures(1, &rhw.tex)
		gl.GenRenderbuffers(1, &rhw.rb)
	}
	if w == rhw.w && h == rhw.h do return
	rhw.w, rhw.h = w, h
	gl.BindTexture(gl.TEXTURE_2D, rhw.tex)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, nil)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	swizzle := [4]i32{gl.RED, gl.GREEN, gl.BLUE, gl.ONE} // cores leave junk in alpha
	gl.TexParameteriv(gl.TEXTURE_2D, gl.TEXTURE_SWIZZLE_RGBA, &swizzle[0])
	gl.BindTexture(gl.TEXTURE_2D, 0)
	gl.BindFramebuffer(gl.FRAMEBUFFER, rhw.fbo)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, rhw.tex, 0)
	if rhw.cb.depth || rhw.cb.stencil {
		gl.BindRenderbuffer(gl.RENDERBUFFER, rhw.rb)
		gl.RenderbufferStorage(gl.RENDERBUFFER, gl.DEPTH24_STENCIL8, w, h)
		gl.FramebufferRenderbuffer(gl.FRAMEBUFFER, gl.DEPTH_STENCIL_ATTACHMENT, gl.RENDERBUFFER, rhw.rb)
		gl.BindRenderbuffer(gl.RENDERBUFFER, 0)
	}
	gl.ClearColor(0, 0, 0, 1)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT | gl.STENCIL_BUFFER_BIT)
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
}

// Wraps retro_run (and anything else that may touch GL) in the core's context.
retro_hw_begin :: proc() {
	if !rhw.ready do return
	rhw.depth += 1
	if rhw.depth == 1 do win.wglMakeCurrent(rhw.hdc, rhw.core_ctx)
}

retro_hw_end :: proc() {
	if !rhw.ready do return
	rhw.depth -= 1
	if rhw.depth > 0 do return
	gl.Flush() // the shared texture must be complete before raylib samples it
	win.wglMakeCurrent(rhw.hdc, rhw.main_ctx)
}

// The frame as a raylib texture + the source rect (flipped: GL rows start at the bottom).
retro_hw_texture :: proc() -> (tex: rl.Texture2D, src: rl.Rectangle, ok: bool) {
	if !rhw.ready || !rhw.frame do return
	tex = rl.Texture2D{id = rhw.tex, width = rhw.w, height = rhw.h, mipmaps = 1, format = .UNCOMPRESSED_R8G8B8A8}
	fw, fh := f32(retro.frame_w), f32(retro.frame_h)
	// the core renders its frame into rows 0..fh with GL's bottom-left origin: show it flipped
	src = rl.Rectangle{0, 0, fw, -fh}
	return tex, src, true
}

retro_hw_stop :: proc() {
	if rhw.ready {
		win.wglMakeCurrent(rhw.hdc, rhw.core_ctx)
		if rhw.cb.context_destroy != nil do rhw.cb.context_destroy()
		gl.DeleteFramebuffers(1, &rhw.fbo)
		gl.DeleteRenderbuffers(1, &rhw.rb)
		gl.DeleteTextures(1, &rhw.tex)
		win.wglMakeCurrent(rhw.hdc, rhw.main_ctx)
		win.wglDeleteContext(rhw.core_ctx)
	}
	if rhw.opengl32 != nil do win.FreeLibrary(rhw.opengl32)
	rhw = {}
}

