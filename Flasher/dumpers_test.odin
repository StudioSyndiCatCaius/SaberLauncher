package flasher

import "core:os"
import "core:testing"

@(test)
test_serial_from_boot :: proc(t: ^testing.T) {
	testing.expect_value(t, serial_from_boot(` cdrom0:\SLUS_204.69;1`), "SLUS-20469")
	testing.expect_value(t, serial_from_boot(`cdrom:\SLUS_006.64;1`), "SLUS-00664")
	testing.expect_value(t, serial_from_boot(`cdrom:SCES_012.37;1`), "SCES-01237")
}

@(test)
test_cover_sources :: proc(t: ^testing.T) {
	ps2 := cover_sources(.PS2)
	testing.expect(t, len(ps2) > 0, "ps2.lua covers_source")
	if len(ps2) > 0 {
		testing.expect_value(t, cover_url(ps2[0], "SLUS-20469"), "https://raw.githubusercontent.com/xlenore/ps2-covers/main/covers/default/SLUS-20469.jpg")
	}
	testing.expect(t, len(cover_sources(.PS1)) > 0, "ps1.lua covers_source")
	testing.expect_value(t, cover_url("https://example.com/{serial}.png", "SLUS-1"), "https://example.com/SLUS-1.png")
}

// Needs internet.
@(test)
test_fetch_cover :: proc(t: ^testing.T) {
	p := fetch_cover(.PS2, "SLUS-20469")
	testing.expect(t, p != "" && file_size(p) > 10_000, p)
	if p != "" do os.remove(p)
	testing.expect_value(t, fetch_cover(.PS2, "NOPE-00000"), "")
}
