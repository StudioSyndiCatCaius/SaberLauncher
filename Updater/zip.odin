package updater

import "core:bytes"
import "core:compress/zlib"
import "core:encoding/endian"
import "core:hash"
import "core:path/filepath"

// Minimal zip reader: returns the entries whose file name (any folder) is in `wanted`.
// Handles stored and deflate entries, no zip64 (release zips are a few MB).
zip_extract :: proc(data: []byte, wanted: []string) -> (files: map[string][]byte, err: string) {
	u16le :: proc(b: []byte, at: int) -> int {v, _ := endian.get_u16(b[at:], .Little); return int(v)}
	u32le :: proc(b: []byte, at: int) -> int {v, _ := endian.get_u32(b[at:], .Little); return int(v)}

	// End of central directory record: last "PK\x05\x06" (may be followed by a comment).
	eocd := -1
	for i := len(data) - 22; i >= max(0, len(data) - 22 - 0xFFFF); i -= 1 {
		if u32le(data, i) == 0x06054b50 {
			eocd = i
			break
		}
	}
	if eocd < 0 do return nil, "no end-of-central-directory record"
	count := u16le(data, eocd + 10)
	at := u32le(data, eocd + 16)

	files = make(map[string][]byte)
	for _ in 0 ..< count {
		if at + 46 > len(data) || u32le(data, at) != 0x02014b50 do return files, "broken central directory"
		method := u16le(data, at + 10)
		crc := u32(u32le(data, at + 16))
		comp_size := u32le(data, at + 20)
		size := u32le(data, at + 24)
		name_len := u16le(data, at + 28)
		local := u32le(data, at + 42)
		if at + 46 + name_len > len(data) do return files, "broken central directory"
		name := string(data[at + 46:][:name_len])
		at += 46 + name_len + u16le(data, at + 30) + u16le(data, at + 32)

		base := filepath.base(name)
		is_wanted := false
		for w in wanted do if w == base do is_wanted = true
		if !is_wanted do continue

		if local + 30 > len(data) || u32le(data, local) != 0x04034b50 do return files, "broken local header"
		start := local + 30 + u16le(data, local + 26) + u16le(data, local + 28)
		if start + comp_size > len(data) do return files, "truncated entry"
		raw := data[start:][:comp_size]

		out: []byte
		switch method {
		case 0:
			out = raw
		case 8:
			buf: bytes.Buffer
			if zlib.inflate_from_byte_array_raw(raw, &buf, expected_output_size = size) != nil {
				return files, "cannot inflate entry"
			}
			out = bytes.buffer_to_bytes(&buf)
		case:
			return files, "unsupported compression method"
		}
		if len(out) != size || hash.crc32(out) != crc do return files, "CRC mismatch"
		files[base] = out
	}
	return files, ""
}
