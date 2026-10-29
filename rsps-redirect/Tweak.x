// RSPSRedirect: point a clone of the OSRS app at Kyle's own server, and only the clone.
//
// Two apps, two jobs:
//   - com.kylef.ageofash ("Age of Ash"), a re-signed copy of the OSRS app, is always
//     redirected unless the prefs set CloneDisabled.
//   - com.jagex.oldschool, the stock app Kyle plays real OSRS and records traces in, is never
//     redirected. Its only job here is to write out its one FairPlay-encrypted page (4 KB,
//     decrypted in memory) when the prefs set DumpPage, so the clone can be built. Once the
//     clone exists, the stock app comes out of the filter plist.
// Prefs: /var/jb/var/mobile/Library/Preferences/com.kylef.rspsredirect.plist
//
// When redirecting it rewrites three C strings in the app's __TEXT,__cstring, in memory only
// (MSHookMemory, ElleKit), the same three things RuneLite gets patched for on the PC:
//   - the 1024-bit RSA modulus (hex), replaced by the server's, same length;
//   - the jav_config URL and the world list (slr.ws) URL, replaced by local ones, which
//     must be no longer than the originals (the rest is NUL-filled).
// The file on disk, its signature and its FairPlay page are never touched.
//
// In the clone it also turns the app's exception-port calls into no-ops: the kernel killed the
// ad hoc signed clone with EXC_GUARD SET_EXCEPTION_BEHAVIOR when its crash reporter called
// task_swap_exception_ports (osclient+0x23bf68), 2026-10-29. The stock app is never hooked.
//
// Log: <app container>/tmp/rsps_redirect.log, and every line also goes to NSLog ("RSPSRedirect:").

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <string.h>

#define PREFS "/var/jb/var/mobile/Library/Preferences/com.kylef.rspsredirect.plist"
#define STOCK_CONFIG "https://oldschool.config.runescape.com/jav_config.ws?m=0"
#define STOCK_WORLDS "https://oldschool.config.runescape.com/slr.ws?order=LPWM"
#define MODULUS_HEX_LEN 256

static FILE *rlog_file;

static void rlog(const char *fmt, ...) {
	char line[512];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(line, sizeof line, fmt, ap);
	va_end(ap);
	NSLog(@"RSPSRedirect: %s", line);
	if (rlog_file) {
		fprintf(rlog_file, "%s\n", line);
		fflush(rlog_file);
	}
}

typedef void (*hook_memory_t)(void *target, const void *data, size_t size);
typedef void (*hook_function_t)(void *symbol, void *replace, void **result);

static void *orig_set_exception_ports, *orig_swap_exception_ports;

static kern_return_t fake_set_exception_ports(task_t task, exception_mask_t mask, mach_port_t port,
                                              exception_behavior_t behavior, thread_state_flavor_t flavor) {
	rlog("task_set_exception_ports(mask 0x%x, behavior 0x%x): skipped", mask, behavior);
	return KERN_SUCCESS;
}

static kern_return_t fake_swap_exception_ports(task_t task, exception_mask_t mask, mach_port_t port,
                                               exception_behavior_t behavior, thread_state_flavor_t flavor,
                                               exception_mask_array_t masks, mach_msg_type_number_t *count,
                                               exception_handler_array_t ports, exception_behavior_array_t behaviors,
                                               exception_flavor_array_t flavors) {
	rlog("task_swap_exception_ports(mask 0x%x, behavior 0x%x): skipped", mask, behavior);
	if (count) *count = 0;  // no previous handlers to hand back
	return KERN_SUCCESS;
}

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

// Find osclient by name: at tweak load, image 0 was not the app (its __cstring held 2249
// bytes, against osclient's 683 KB), 2026-10-29.
static const struct mach_header_64 *find_osclient(void) {
	for (uint32_t i = 0; i < _dyld_image_count(); i++) {
		const char *name = _dyld_get_image_name(i);
		size_t n = name ? strlen(name) : 0;
		if (n >= 9 && strcmp(name + n - 9, "/osclient") == 0) {
			rlog("osclient is image %u", i);
			return (const struct mach_header_64 *)_dyld_get_image_header(i);
		}
	}
	rlog("osclient image not found");
	return NULL;
}

// Write the FairPlay range, which the kernel has decrypted in memory by now, to tmp.
static void dump_crypt_page(const struct mach_header_64 *mh) {
	const struct load_command *lc = (const struct load_command *)(mh + 1);
	for (uint32_t i = 0; i < mh->ncmds; i++, lc = (const struct load_command *)((const char *)lc + lc->cmdsize)) {
		if (lc->cmd != LC_ENCRYPTION_INFO_64) continue;
		const struct encryption_info_command_64 *e = (const struct encryption_info_command_64 *)lc;
		NSString *out = [NSTemporaryDirectory() stringByAppendingPathComponent:@"osclient_crypt_page.bin"];
		FILE *f = fopen(out.fileSystemRepresentation, "wb");
		if (!f) {
			rlog("dump: cannot write %s", out.UTF8String);
			return;
		}
		fwrite((const char *)mh + e->cryptoff, 1, e->cryptsize, f);
		fclose(f);
		rlog("dump: cryptoff %u cryptsize %u cryptid %u -> %s", e->cryptoff, e->cryptsize, e->cryptid, out.UTF8String);
		return;
	}
	rlog("dump: no LC_ENCRYPTION_INFO_64");
}

%ctor {
	NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@PREFS];
	NSString *bundle = [NSBundle mainBundle].bundleIdentifier;
	BOOL stock = [bundle isEqualToString:@"com.jagex.oldschool"];
	if (stock && ![prefs[@"DumpPage"] boolValue]) return;  // the stock app: touch nothing
	if (!stock && [prefs[@"CloneDisabled"] boolValue]) return;

	NSString *logPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"rsps_redirect.log"];
	rlog_file = fopen(logPath.fileSystemRepresentation, "a");
	rlog("--- %s RSPSRedirect in %s", [[NSDate date] description].UTF8String, bundle.UTF8String);
	if (stock) {
		const struct mach_header_64 *mh = find_osclient();
		if (mh) dump_crypt_page(mh);
		return;  // never redirect the stock app
	}

	// The tweak loader does not bring ElleKit into the process unless a tweak links it, so open
	// it here; RTLD_DEFAULT alone found nothing on 2026-10-29.
	void *ek = dlopen("/var/jb/usr/lib/libellekit.dylib", RTLD_NOW);
	hook_function_t hook_fn = (hook_function_t)(ek ? dlsym(ek, "MSHookFunction") : dlsym(RTLD_DEFAULT, "MSHookFunction"));
	if (hook_fn) {
		hook_fn((void *)task_set_exception_ports, (void *)fake_set_exception_ports, &orig_set_exception_ports);
		hook_fn((void *)task_swap_exception_ports, (void *)fake_swap_exception_ports, &orig_swap_exception_ports);
		rlog("exception-port calls hooked");
	} else {
		rlog("MSHookFunction not found (dlopen ellekit: %s): exception ports not hooked", ek ? "ok" : dlerror());
	}

	NSString *modulus = prefs[@"Modulus"], *config = prefs[@"ConfigURL"], *worlds = prefs[@"WorldListURL"];
	if (modulus.length != MODULUS_HEX_LEN || !config || !worlds) {
		rlog("prefs incomplete (Modulus %lu chars, ConfigURL %s, WorldListURL %s): nothing patched",
		     (unsigned long)modulus.length, config ? "set" : "missing", worlds ? "set" : "missing");
		return;
	}
	hook_memory_t hook = (hook_memory_t)(ek ? dlsym(ek, "MSHookMemory") : dlsym(RTLD_DEFAULT, "MSHookMemory"));
	if (!hook) {
		rlog("MSHookMemory not found (dlopen ellekit: %s): nothing patched", ek ? "ok" : dlerror());
		return;
	}
	const struct mach_header_64 *mh = find_osclient();
	if (!mh) return;
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
