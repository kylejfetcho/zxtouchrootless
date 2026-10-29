// RSPSRedirect: point the official OSRS app (com.jagex.oldschool) at Kyle's own server.
//
// Inert unless /var/jb/var/mobile/Library/Preferences/com.kylef.rspsredirect.plist has
// Enabled = true. Kyle plays real OSRS and records touch traces in this same app, so off
// must mean untouched: no patch, no hook, nothing but one plist read at launch.
//
// When enabled it rewrites three C strings in the app's __TEXT,__cstring, in memory only
// (MSHookMemory, ElleKit), the same three things RuneLite gets patched for on the PC:
//   - the 1024-bit RSA modulus (hex), replaced by the server's, same length;
//   - the jav_config URL and the world list (slr.ws) URL, replaced by local ones, which
//     must be no longer than the originals (the rest is NUL-filled).
// The file on disk, its signature and its FairPlay page are never touched.
//
// Log: <app container>/tmp/rsps_redirect.log

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <string.h>

#define PREFS "/var/jb/var/mobile/Library/Preferences/com.kylef.rspsredirect.plist"
#define STOCK_CONFIG "https://oldschool.config.runescape.com/jav_config.ws?m=0"
#define STOCK_WORLDS "https://oldschool.config.runescape.com/slr.ws?order=LPWM"
#define MODULUS_HEX_LEN 256

static FILE *rlog_file;

static void rlog(const char *fmt, ...) {
	va_list ap;
	va_start(ap, fmt);
	if (rlog_file) {
		vfprintf(rlog_file, fmt, ap);
		fputc('\n', rlog_file);
		fflush(rlog_file);
	}
	va_end(ap);
}

typedef void (*hook_memory_t)(void *target, const void *data, size_t size);

// Replace every occurrence of `from` (a whole NUL-terminated string) in the section with `to`,
// NUL-padded to from's length. Returns the number replaced.
static int patch_all(hook_memory_t hook, char *sect, unsigned long size, const char *from, const char *to) {
	size_t flen = strlen(from), tlen = strlen(to);
	if (tlen > flen) {
		rlog("skip: replacement longer than original (%zu > %zu) for %.40s", tlen, flen, from);
		return 0;
	}
	char buf[512];
	if (flen + 1 > sizeof buf) return 0;
	memset(buf, 0, sizeof buf);
	memcpy(buf, to, tlen);
	int n = 0;
	char *p = sect, *end = sect + size;
	while (p < end) {
		char *hit = memmem(p, (size_t)(end - p), from, flen + 1);  // include the NUL: whole string only
		if (!hit) break;
		hook(hit, buf, flen + 1);
		n++;
		p = hit + flen + 1;
	}
	return n;
}

// The stock modulus is the only 256-char run of lowercase hex in __cstring.
static int patch_modulus(hook_memory_t hook, char *sect, unsigned long size, const char *modulus) {
	int n = 0;
	char *s = sect, *end = sect + size;
	while (s < end) {
		size_t len = strnlen(s, (size_t)(end - s));
		if (len == MODULUS_HEX_LEN && strspn(s, "0123456789abcdef") == MODULUS_HEX_LEN && strcmp(s, modulus) != 0) {
			rlog("modulus found at +0x%lx: %.16s...", (unsigned long)(s - sect), s);
			hook(s, modulus, MODULUS_HEX_LEN);
			n++;
		}
		s += len + 1;
	}
	return n;
}

%ctor {
	NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@PREFS];
	if (![prefs[@"Enabled"] boolValue]) return;  // off: touch nothing

	NSString *logPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"rsps_redirect.log"];
	rlog_file = fopen(logPath.fileSystemRepresentation, "a");
	rlog("--- %s RSPSRedirect enabled", [[NSDate date] description].UTF8String);

	NSString *modulus = prefs[@"Modulus"], *config = prefs[@"ConfigURL"], *worlds = prefs[@"WorldListURL"];
	if (modulus.length != MODULUS_HEX_LEN || !config || !worlds) {
		rlog("prefs incomplete (Modulus %lu chars, ConfigURL %s, WorldListURL %s): nothing patched",
		     (unsigned long)modulus.length, config ? "set" : "missing", worlds ? "set" : "missing");
		return;
	}
	hook_memory_t hook = (hook_memory_t)dlsym(RTLD_DEFAULT, "MSHookMemory");
	if (!hook) {
		rlog("MSHookMemory not found: is ElleKit loaded? nothing patched");
		return;
	}
	const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header(0);
	unsigned long size = 0;
	char *sect = (char *)getsectiondata(mh, "__TEXT", "__cstring", &size);
	if (!sect) {
		rlog("no __TEXT,__cstring in the main image: nothing patched");
		return;
	}
	rlog("__cstring %lu bytes", size);
	int m = patch_modulus(hook, sect, size, modulus.lowercaseString.UTF8String);
	int c = patch_all(hook, sect, size, STOCK_CONFIG, config.UTF8String);
	int w = patch_all(hook, sect, size, STOCK_WORLDS, worlds.UTF8String);
	rlog("patched modulus x%d, config url x%d, world list url x%d", m, c, w);
}
