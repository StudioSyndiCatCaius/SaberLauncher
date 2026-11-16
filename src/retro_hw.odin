package saber

// Hardware-rendered cores (PSP, PS2...), ported from SimpRetro. The core gets its own
// OpenGL context sharing objects with raylib's, so neither side tramples the other's
// cached GL state; it draws into an FBO whose colour texture raylib then presents.
// The core's context is current only while it runs (context_reset / retro_run / destroy).
// The contexts themselves (WGL / GLX) are in hwgl_<os>.odin.

import rl "vendor:raylib"

// The few GL entry points used here, loaded from the core's context (the whole
// vendor:OpenGL loader cost ~40 KB of exe for these).
Hw_Gl_Api :: struct {
	GenFramebuffers, GenTextures, GenRenderbuffers:          proc "system" (n: i32, ids: ^u32),
	DeleteFramebuffers, DeleteTextures, DeleteRenderbuffers: proc "system" (n: i32, ids: ^u32),
	BindTexture, BindFramebuffer, BindRenderbuffer:          proc "system" (target, id: u32),
	TexImage2D:              proc "system" (target: u32, level, ifmt, w, h, border: i32, fmt, type: u32, px: rawptr),
	TexParameteri:           proc "system" (target, name: u32, v: i32),
	TexParameteriv:          proc "system" (target, name: u32, v: [^]i32),
	FramebufferTexture2D:    proc "system" (target, attach, textarget, tex: u32, level: i32),
	RenderbufferStorage:     proc "system" (target, fmt: u32, w, h: i32),
	FramebufferRenderbuffer: proc "system" (target, attach, rbtarget, rb: u32),
	ClearColor:              proc "system" (r, g, b, a: f32),
	Clear:                   proc "system" (mask: u32),
	Flush:                   proc "system" (),
}

GL_TEXTURE_2D :: 0x0DE1
GL_FRAMEBUFFER :: 0x8D40
GL_RENDERBUFFER :: 0x8D41

gl: Hw_Gl_Api

hw_gl_load :: proc() -> bool {
	names := [?]cstring{"glGenFramebuffers", "glGenTextures", "glGenRenderbuffers", "glDeleteFramebuffers", "glDeleteTextures", "glDeleteRenderbuffers", "glBindTexture", "glBindFramebuffer", "glBindRenderbuffer", "glTexImage2D", "glTexParameteri", "glTexParameteriv", "glFramebufferTexture2D", "glRenderbufferStorage", "glFramebufferRenderbuffer", "glClearColor", "glClear", "glFlush"}
	#assert(len(names) * size_of(rawptr) == size_of(Hw_Gl_Api))
	slots := ([^]rawptr)(&gl)
	for n, i in names {
		slots[i] = hw_gl_proc_address(&rhw.ctx, n)
		if slots[i] == nil do return false
	}
	return true
}

Retro_Hw :: struct {
	enabled:  bool,
	cb:       HW_Render_Callback,
	ready:    bool,
	ctx:      Hw_Gl,    // raylib's context and the core's
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
	return hw_gl_proc_address(&rhw.ctx, sym)
}

// After load_game: creates the core's context + framebuffer and calls context_reset.
retro_hw_start :: proc(max_w, max_h: i32) -> bool {
	if !rhw.enabled do return true
	if !hw_gl_bind_main(&rhw.ctx) do return false

	core := rhw.cb.context_type == .OPENGL_CORE
	versions := [?][2]i32{{4, 6}, {4, 5}, {4, 4}, {4, 3}, {4, 2}, {4, 1}, {4, 0}, {3, 3}, {3, 2}}
	created := false
	for v in versions {
		if core && (v[0] < i32(rhw.cb.version_major) || (v[0] == i32(rhw.cb.version_major) && v[1] < i32(rhw.cb.version_minor))) do continue
		if hw_gl_create(&rhw.ctx, v[0], v[1], core) {
			retro_log_line("[hw] core GL context %d.%d %s", v[0], v[1], core ? "core" : "compat")
			created = true
			break
		}
	}
	if !created do return false

	// GL entry points of the core's context (the same driver serves raylib's)
	hw_gl_use_core(&rhw.ctx)
	if !hw_gl_load() {
		hw_gl_use_main(&rhw.ctx)
		return false
	}
	rhw.ready = true
	retro_hw_resize(max_w, max_h)
	if rhw.cb.context_reset != nil do rhw.cb.context_reset()
	hw_gl_use_main(&rhw.ctx)
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
	gl.BindTexture(GL_TEXTURE_2D, rhw.tex)
	gl.TexImage2D(GL_TEXTURE_2D, 0, 0x8058 /*RGBA8*/, w, h, 0, 0x1908 /*RGBA*/, 0x1401 /*UNSIGNED_BYTE*/, nil)
	gl.TexParameteri(GL_TEXTURE_2D, 0x2801 /*MIN_FILTER*/, 0x2601 /*LINEAR*/)
	gl.TexParameteri(GL_TEXTURE_2D, 0x2800 /*MAG_FILTER*/, 0x2601)
	gl.TexParameteri(GL_TEXTURE_2D, 0x2802 /*WRAP_S*/, 0x812F /*CLAMP_TO_EDGE*/)
	gl.TexParameteri(GL_TEXTURE_2D, 0x2803 /*WRAP_T*/, 0x812F)
	swizzle := [4]i32{0x1903, 0x1904, 0x1905, 1} // RGB + ONE: cores leave junk in alpha
	gl.TexParameteriv(GL_TEXTURE_2D, 0x8E46 /*SWIZZLE_RGBA*/, &swizzle[0])
	gl.BindTexture(GL_TEXTURE_2D, 0)
	gl.BindFramebuffer(GL_FRAMEBUFFER, rhw.fbo)
	gl.FramebufferTexture2D(GL_FRAMEBUFFER, 0x8CE0 /*COLOR_ATTACHMENT0*/, GL_TEXTURE_2D, rhw.tex, 0)
	if rhw.cb.depth || rhw.cb.stencil {
		gl.BindRenderbuffer(GL_RENDERBUFFER, rhw.rb)
		gl.RenderbufferStorage(GL_RENDERBUFFER, 0x88F0 /*DEPTH24_STENCIL8*/, w, h)
		gl.FramebufferRenderbuffer(GL_FRAMEBUFFER, 0x821A /*DEPTH_STENCIL_ATTACHMENT*/, GL_RENDERBUFFER, rhw.rb)
		gl.BindRenderbuffer(GL_RENDERBUFFER, 0)
	}
	gl.ClearColor(0, 0, 0, 1)
	gl.Clear(0x4000 | 0x100 | 0x400) // colour | depth | stencil
	gl.BindFramebuffer(GL_FRAMEBUFFER, 0)
}

// Wraps retro_run (and anything else that may touch GL) in the core's context.
retro_hw_begin :: proc() {
	if !rhw.ready do return
	rhw.depth += 1
	if rhw.depth == 1 do hw_gl_use_core(&rhw.ctx)
}

retro_hw_end :: proc() {
	if !rhw.ready do return
	rhw.depth -= 1
	if rhw.depth > 0 do return
	gl.Flush() // the shared texture must be complete before raylib samples it
	hw_gl_use_main(&rhw.ctx)
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
		hw_gl_use_core(&rhw.ctx)
		if rhw.cb.context_destroy != nil do rhw.cb.context_destroy()
		gl.DeleteFramebuffers(1, &rhw.fbo)
		gl.DeleteRenderbuffers(1, &rhw.rb)
		gl.DeleteTextures(1, &rhw.tex)
		hw_gl_use_main(&rhw.ctx)
	}
	hw_gl_destroy(&rhw.ctx)
	rhw = {}
}

