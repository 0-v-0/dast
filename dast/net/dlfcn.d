module dast.net.dlfcn;

version (Posix)
	public import core.sys.posix.dlfcn : dlclose, dlopen, dlsym, RTLD_LAZY, RTLD_NOW, RTLD_GLOBAL, RTLD_LOCAL;
else version (Windows){
	import core.sys.windows.windows;
	enum {
		RTLD_LAZY = 0x00001,
		RTLD_NOW = 0x00002,
		RTLD_GLOBAL = 0x00100,
		RTLD_LOCAL = 0,
	}
}else
	static assert(0, "unimplemented");

nothrow @nogc:

string dlerr() @trusted {
	import std.string : fromStringz;
	version (Posix) {
		import core.sys.posix.dlfcn : dlerror;

		return cast(string)fromStringz(dlerror());
	} else version (Windows) {
		if (errorOccurred) {
			errorOccurred = false;
			return cast(string)fromStringz(errorBuffer.ptr);
		}
		return null;
	}
}

version (Windows):

import core.stdc.string : memcpy, strlen;

void* dlopen(const char* filename, int) @trusted {
	errorOccurred = false;

	HMODULE handle = LoadLibraryA(filename);
	if (handle is null)
		saveErrStr(filename, GetLastError());

	return handle;
}

alias dlsym = GetProcAddress;

int dlclose(HMODULE handle) @trusted {
	errorOccurred = false;

	BOOL ret = FreeLibrary(handle);
	if (!ret)
		saveErrPtrStr(handle, GetLastError());

	/* dlclose's return value in inverted in relation to FreeLibrary's. */
	return !ret;
}

private:
// From https://github.com/dlfcn-win32/dlfcn-win32/blob/048bff80f2bd00bb651bcc3357cb6f76e3d76fd5/src/dlfcn.c#L176

/* POSIX says dlerror( ) doesn't have to be thread-safe, so we use one
 * static buffer.
 * MSDN says the buffer cannot be larger than 64K bytes, so we set it to
 * the limit.
 */
__gshared {
	char[65_535] errorBuffer = void;
	bool errorOccurred;
}

void saveErrStr(const char* str, uint dwMessageId) {
	size_t len = strlen(str);
	if (len > errorBuffer.sizeof - 5)
		len = errorBuffer.sizeof - 5;

	// Format error message to:
	// "<argument to function that failed>": <Windows localized error message>
	size_t pos = 0;
	errorBuffer[pos++] = '"';
	memcpy(errorBuffer.ptr + pos, str, len);
	pos += len;
	errorBuffer[pos++] = '"';
	errorBuffer[pos++] = ':';
	errorBuffer[pos++] = ' ';

	uint ret = FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, null, dwMessageId,
		MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
		errorBuffer.ptr + pos, cast(uint)(errorBuffer.sizeof - pos), null);
	pos += ret;

	// When FormatMessageA() fails it returns zero and does not touch buffer
	// so add trailing null byte
	if (ret == 0)
		errorBuffer[pos] = '\0';

	if (pos > 1) {
		// POSIX says the string must not have trailing <newline>
		if (errorBuffer[pos - 2] == '\r' && errorBuffer[pos - 1] == '\n')
			errorBuffer[pos - 2] = '\0';
	}

	errorOccurred = true;
}

void saveErrPtrStr(const void* ptr, uint dwMessageId) {
	char[2 + 2 * ptr.sizeof + 1] ptrBuf = void;

	ptrBuf[0] = '0';
	ptrBuf[1] = 'x';

	for (size_t i; i < 2 * ptr.sizeof; i++) {
		const num = cast(ulong)ptr >> (8 * ptr.sizeof - 4 * (i + 1)) & 0xF;
		ptrBuf[2 + i] = cast(char)(num + (num < 0xA ? '0' : 'A' - 0xA));
	}

	ptrBuf[2 + 2 * ptr.sizeof] = 0;

	saveErrStr(ptrBuf.ptr, dwMessageId);
}
