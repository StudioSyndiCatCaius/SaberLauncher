package saber

import "core:fmt"
import win "core:sys/windows"

// Raw optical drive access for retro_disc.odin / retro_dreamcast.odin, through the CD-ROM IOCTLs.

IOCTL_CDROM_READ_TOC :: 0x00024000
IOCTL_CDROM_RAW_READ :: 0x0002403E
IOCTL_CDROM_READ_TOC_EX :: 0x00024054
IOCTL_CDROM_GET_CONFIGURATION :: 0x00024058
CDROM_READ_TOC_EX_FORMAT_FULL_TOC :: 2

Disc_Handle :: win.HANDLE

RAW_READ_INFO :: struct #packed {
	disk_offset:  i64,
	sector_count: u32,
	track_mode:   u32,
}

Get_Configuration_Input :: struct {
	feature:      u32, // 0 = profile list
	request_type: u32, // 1 = current
	reserved:     [2]rawptr,
}

disc_open :: proc(letter: u8) -> (Disc_Handle, bool) {
	path := fmt.tprintf(`\\.\%c:`, letter)
	h := win.CreateFileW(win.utf8_to_wstring(path), win.GENERIC_READ, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE, nil, win.OPEN_EXISTING, 0, nil)
	return h, h != win.INVALID_HANDLE_VALUE
}

disc_close :: proc(h: Disc_Handle) {
	win.CloseHandle(h)
}

disc_last_error :: proc() -> int {
	return int(win.GetLastError())
}

// The MMC READ TOC (format 0, MSF addresses) response: 4-byte header + 8 bytes per track.
disc_read_toc_raw :: proc(h: Disc_Handle, raw: []u8) -> bool {
	got: u32
	return bool(win.DeviceIoControl(h, IOCTL_CDROM_READ_TOC, nil, 0, &raw[0], u32(len(raw)), &got, nil))
}

// The MMC READ TOC full TOC (format 2, MSF) from session 1: 4-byte header + 11 bytes per descriptor.
disc_read_full_toc_raw :: proc(h: Disc_Handle, raw: []u8) -> (got: int, ok: bool) {
	input: [4]u8
	input[0] = CDROM_READ_TOC_EX_FORMAT_FULL_TOC | 0x80 // Format (low 4 bits), Msf (top bit)
	input[1] = 1 // first session
	n: u32
	if !win.DeviceIoControl(h, IOCTL_CDROM_READ_TOC_EX, &input[0], len(input), &raw[0], u32(len(raw)), &n, nil) do return
	return int(n), true
}

// len(buf) / ISO_SECTOR user-data sectors starting at lba.
disc_read_user :: proc(h: Disc_Handle, lba: int, buf: []u8) -> bool {
	got: u32
	return bool(win.SetFilePointerEx(h, win.LARGE_INTEGER(i64(lba) * ISO_SECTOR), nil, win.FILE_BEGIN)) &&
		bool(win.ReadFile(h, &buf[0], u32(len(buf)), &got, nil)) && got == u32(len(buf))
}

// n raw 2352-byte sectors starting at lba; `mode` is a TRACK_MODE_*.
disc_read_raw :: proc(h: Disc_Handle, lba, n: int, mode: u32, dst: []u8) -> bool {
	info := RAW_READ_INFO{disk_offset = i64(lba) * ISO_SECTOR, sector_count = u32(n), track_mode = mode}
	got: u32
	return bool(win.DeviceIoControl(h, IOCTL_CDROM_RAW_READ, &info, size_of(info), &dst[0], u32(n * RAW_SECTOR), &got, nil)) && got == u32(n * RAW_SECTOR)
}

// The drive's current MMC profile (0x08 CD-ROM, 0x09 CD-R, 0x10 DVD-ROM, 0x1A DVD+RW, ...); 0 = unknown.
disc_profile :: proc(h: Disc_Handle) -> u16 {
	input := Get_Configuration_Input{feature = 0, request_type = 1}
	out: [8]byte
	got: u32
	if !win.DeviceIoControl(h, IOCTL_CDROM_GET_CONFIGURATION, &input, size_of(input), &out[0], len(out), &got, nil) || got < 8 do return 0
	return u16(out[6]) << 8 | u16(out[7])
}
