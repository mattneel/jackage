const __root = @This();
pub const __builtin = @import("std").zig.c_translation.builtins;
pub const __helpers = @import("std").zig.c_translation.helpers;
pub const __builtin_va_list = [*c]u8;
pub const __gnuc_va_list = __builtin_va_list;
pub const va_list = __gnuc_va_list;
pub extern fn __mingw_get_crt_info() [*c]const u8;
pub const rsize_t = usize;
pub const ptrdiff_t = c_longlong;
pub const wchar_t = c_ushort;
pub const wint_t = c_ushort;
pub const wctype_t = c_ushort;
pub const errno_t = c_int;
pub const __time32_t = c_long;
pub const __time64_t = c_longlong;
pub const time_t = __time64_t;
pub extern fn _invalid_parameter_noinfo() void;
pub extern fn _invalid_parameter_noinfo_noreturn() noreturn;
pub extern fn _invoke_watson(expression: [*c]const wchar_t, function_name: [*c]const wchar_t, file_name: [*c]const wchar_t, line_number: c_uint, reserved: c_ulonglong) noreturn;
pub const struct_threadlocaleinfostruct = opaque {};
pub const struct_threadmbcinfostruct = opaque {};
pub const pthreadlocinfo = ?*struct_threadlocaleinfostruct;
pub const pthreadmbcinfo = ?*struct_threadmbcinfostruct;
pub const struct___lc_time_data = opaque {};
pub const struct_localeinfo_struct = extern struct {
    locinfo: pthreadlocinfo = null,
    mbcinfo: pthreadmbcinfo = null,
};
pub const _locale_tstruct = struct_localeinfo_struct;
pub const _locale_t = [*c]struct_localeinfo_struct;
pub const struct_tagLC_ID = extern struct {
    wLanguage: c_ushort = 0,
    wCountry: c_ushort = 0,
    wCodePage: c_ushort = 0,
};
pub const LC_ID = struct_tagLC_ID;
pub const LPLC_ID = [*c]struct_tagLC_ID;
pub extern fn __local_stdio_printf_options() [*c]c_ulonglong;
pub extern fn __local_stdio_scanf_options() [*c]c_ulonglong;
pub const struct__iobuf = extern struct {
    _Placeholder: ?*anyopaque = null,
    pub const __mingw_fscanf = __root.__mingw_fscanf;
    pub const __mingw_vfscanf = __root.__mingw_vfscanf;
    pub const __mingw_fprintf = __root.__mingw_fprintf;
    pub const __mingw_vfprintf = __root.__mingw_vfprintf;
    pub const __ms_fscanf = __root.__ms_fscanf;
    pub const __ms_vfscanf = __root.__ms_vfscanf;
    pub const __ms_fprintf = __root.__ms_fprintf;
    pub const __ms_vfprintf = __root.__ms_vfprintf;
    pub const fprintf = __root.fprintf;
    pub const vfprintf = __root.vfprintf;
    pub const fscanf = __root.fscanf;
    pub const vfscanf = __root.vfscanf;
    pub const _filbuf = __root._filbuf;
    pub const clearerr = __root.clearerr;
    pub const fclose = __root.fclose;
    pub const feof = __root.feof;
    pub const ferror = __root.ferror;
    pub const fflush = __root.fflush;
    pub const fgetc = __root.fgetc;
    pub const fgetpos = __root.fgetpos;
    pub const fgetpos64 = __root.fgetpos64;
    pub const _fileno = __root._fileno;
    pub const fsetpos = __root.fsetpos;
    pub const fsetpos64 = __root.fsetpos64;
    pub const fseek = __root.fseek;
    pub const ftell = __root.ftell;
    pub const _fseeki64 = __root._fseeki64;
    pub const _ftelli64 = __root._ftelli64;
    pub const fseeko = __root.fseeko;
    pub const fseeko64 = __root.fseeko64;
    pub const ftello = __root.ftello;
    pub const ftello64 = __root.ftello64;
    pub const getc = __root.getc;
    pub const _getw = __root._getw;
    pub const _pclose = __root._pclose;
    pub const rewind = __root.rewind;
    pub const setbuf = __root.setbuf;
    pub const setvbuf = __root.setvbuf;
    pub const __mingw_fwscanf = __root.__mingw_fwscanf;
    pub const __mingw_vfwscanf = __root.__mingw_vfwscanf;
    pub const __mingw_fwprintf = __root.__mingw_fwprintf;
    pub const __mingw_vfwprintf = __root.__mingw_vfwprintf;
    pub const __ms_fwscanf = __root.__ms_fwscanf;
    pub const __ms_vfwscanf = __root.__ms_vfwscanf;
    pub const __ms_fwprintf = __root.__ms_fwprintf;
    pub const __ms_vfwprintf = __root.__ms_vfwprintf;
    pub const fwscanf = __root.fwscanf;
    pub const vfwscanf = __root.vfwscanf;
    pub const fwprintf = __root.fwprintf;
    pub const vfwprintf = __root.vfwprintf;
    pub const fgetwc = __root.fgetwc;
    pub const getwc = __root.getwc;
    pub const _fgetwc_nolock = __root._fgetwc_nolock;
    pub const _fgetc_nolock = __root._fgetc_nolock;
    pub const _getc_nolock = __root._getc_nolock;
    pub const _lock_file = __root._lock_file;
    pub const _unlock_file = __root._unlock_file;
    pub const _fclose_nolock = __root._fclose_nolock;
    pub const _fflush_nolock = __root._fflush_nolock;
    pub const _fseek_nolock = __root._fseek_nolock;
    pub const _ftell_nolock = __root._ftell_nolock;
    pub const _fseeki64_nolock = __root._fseeki64_nolock;
    pub const _ftelli64_nolock = __root._ftelli64_nolock;
    pub const fileno = __root.fileno;
    pub const getw = __root.getw;
    pub const clearerr_s = __root.clearerr_s;
    pub const _vfscanf_s_l = __root._vfscanf_s_l;
    pub const vfscanf_s = __root.vfscanf_s;
    pub const _fscanf_s_l = __root._fscanf_s_l;
    pub const fscanf_s = __root.fscanf_s;
    pub const _vfscanf_l = __root._vfscanf_l;
    pub const _fscanf_l = __root._fscanf_l;
    pub const _vfprintf_s_l = __root._vfprintf_s_l;
    pub const vfprintf_s = __root.vfprintf_s;
    pub const _fprintf_s_l = __root._fprintf_s_l;
    pub const fprintf_s = __root.fprintf_s;
    pub const _vfprintf_p_l = __root._vfprintf_p_l;
    pub const _vfprintf_p = __root._vfprintf_p;
    pub const _fprintf_p_l = __root._fprintf_p_l;
    pub const _fprintf_p = __root._fprintf_p;
    pub const _vfprintf_l = __root._vfprintf_l;
    pub const _fprintf_l = __root._fprintf_l;
    pub const _vfwscanf_s_l = __root._vfwscanf_s_l;
    pub const vfwscanf_s = __root.vfwscanf_s;
    pub const _fwscanf_s_l = __root._fwscanf_s_l;
    pub const fwscanf_s = __root.fwscanf_s;
    pub const _vfwprintf_s_l = __root._vfwprintf_s_l;
    pub const vfwprintf_s = __root.vfwprintf_s;
    pub const _fwprintf_s_l = __root._fwprintf_s_l;
    pub const fwprintf_s = __root.fwprintf_s;
    pub const JS_DumpMemoryUsage = __root.JS_DumpMemoryUsage;
    pub const filbuf = __root._filbuf;
    pub const fseeki64 = __root._fseeki64;
    pub const ftelli64 = __root._ftelli64;
    pub const nolock = __root._fgetwc_nolock;
    pub const file = __root._lock_file;
    pub const s = __root.clearerr_s;
    pub const l = __root._vfscanf_s_l;
    pub const p = __root._vfprintf_p;
    pub const DumpMemoryUsage = __root.JS_DumpMemoryUsage;
};
pub const FILE = struct__iobuf;
pub const _off_t = c_long;
pub const off32_t = c_long;
pub const _off64_t = c_longlong;
pub const off64_t = c_longlong;
pub const off_t = off32_t;
pub extern fn __acrt_iob_func(index: c_uint) [*c]FILE;
pub extern fn __iob_func() [*c]FILE;
pub const fpos_t = c_longlong;
pub extern fn __mingw_sscanf(noalias _Src: [*c]const u8, noalias _Format: [*c]const u8, ...) c_int;
pub extern fn __mingw_vsscanf(noalias _Str: [*c]const u8, noalias Format: [*c]const u8, argp: va_list) c_int;
pub extern fn __mingw_scanf(noalias _Format: [*c]const u8, ...) c_int;
pub extern fn __mingw_vscanf(noalias Format: [*c]const u8, argp: va_list) c_int;
pub extern fn __mingw_fscanf(noalias _File: [*c]FILE, noalias _Format: [*c]const u8, ...) c_int;
pub extern fn __mingw_vfscanf(noalias fp: [*c]FILE, noalias Format: [*c]const u8, argp: va_list) c_int;
pub extern fn __mingw_vsnprintf(noalias _DstBuf: [*c]u8, _MaxCount: usize, noalias _Format: [*c]const u8, _ArgList: va_list) c_int;
pub extern fn __mingw_snprintf(noalias s: [*c]u8, n: usize, noalias format: [*c]const u8, ...) c_int;
pub extern fn __mingw_printf(noalias [*c]const u8, ...) c_int;
pub extern fn __mingw_vprintf(noalias [*c]const u8, va_list) c_int;
pub extern fn __mingw_fprintf(noalias [*c]FILE, noalias [*c]const u8, ...) c_int;
pub extern fn __mingw_vfprintf(noalias [*c]FILE, noalias [*c]const u8, va_list) c_int;
pub extern fn __mingw_sprintf(noalias [*c]u8, noalias [*c]const u8, ...) c_int;
pub extern fn __mingw_vsprintf(noalias [*c]u8, noalias [*c]const u8, va_list) c_int;
pub extern fn __mingw_asprintf(noalias [*c][*c]u8, noalias [*c]const u8, ...) c_int;
pub extern fn __mingw_vasprintf(noalias [*c][*c]u8, noalias [*c]const u8, va_list) c_int;
pub extern fn __ms_sscanf(noalias _Src: [*c]const u8, noalias _Format: [*c]const u8, ...) c_int;
pub extern fn __ms_vsscanf(noalias _Str: [*c]const u8, noalias _Format: [*c]const u8, argp: va_list) c_int;
pub extern fn __ms_scanf(noalias _Format: [*c]const u8, ...) c_int;
pub extern fn __ms_vscanf(noalias _Format: [*c]const u8, argp: va_list) c_int;
pub extern fn __ms_fscanf(noalias _File: [*c]FILE, noalias _Format: [*c]const u8, ...) c_int;
pub extern fn __ms_vfscanf(noalias _File: [*c]FILE, noalias _Format: [*c]const u8, argp: va_list) c_int;
pub extern fn __ms_printf(noalias [*c]const u8, ...) c_int;
pub extern fn __ms_vprintf(noalias [*c]const u8, va_list) c_int;
pub extern fn __ms_fprintf(noalias [*c]FILE, noalias [*c]const u8, ...) c_int;
pub extern fn __ms_vfprintf(noalias [*c]FILE, noalias [*c]const u8, va_list) c_int;
pub extern fn __ms_sprintf(noalias [*c]u8, noalias [*c]const u8, ...) c_int;
pub extern fn __ms_vsprintf(noalias [*c]u8, noalias [*c]const u8, va_list) c_int;
pub extern fn __ms_snprintf(noalias [*c]u8, usize, noalias [*c]const u8, ...) c_int;
pub extern fn __ms_vsnprintf(noalias [*c]u8, usize, noalias [*c]const u8, va_list) c_int;
pub extern fn __stdio_common_vsprintf(options: c_ulonglong, str: [*c]u8, len: usize, format: [*c]const u8, locale: _locale_t, valist: va_list) c_int;
pub extern fn __stdio_common_vfprintf(options: c_ulonglong, file: [*c]FILE, format: [*c]const u8, locale: _locale_t, valist: va_list) c_int;
pub extern fn __stdio_common_vsscanf(options: c_ulonglong, input: [*c]const u8, length: usize, format: [*c]const u8, locale: _locale_t, valist: va_list) c_int;
pub extern fn __stdio_common_vfscanf(options: c_ulonglong, file: [*c]FILE, format: [*c]const u8, locale: _locale_t, valist: va_list) c_int;
pub extern fn fprintf(noalias _File: [*c]FILE, noalias _Format: [*c]const u8, ...) c_int;
pub extern fn printf(noalias _Format: [*c]const u8, ...) c_int;
pub extern fn sprintf(noalias _Dest: [*c]u8, noalias _Format: [*c]const u8, ...) c_int;
pub extern fn vfprintf(noalias _File: [*c]FILE, noalias _Format: [*c]const u8, _ArgList: va_list) c_int;
pub extern fn vprintf(noalias _Format: [*c]const u8, _ArgList: va_list) c_int;
pub extern fn vsprintf(noalias _Dest: [*c]u8, noalias _Format: [*c]const u8, _Args: va_list) c_int;
pub extern fn fscanf(noalias _File: [*c]FILE, noalias _Format: [*c]const u8, ...) c_int;
pub extern fn scanf(noalias _Format: [*c]const u8, ...) c_int;
pub extern fn sscanf(noalias _Src: [*c]const u8, noalias _Format: [*c]const u8, ...) c_int;
pub extern fn vfscanf(__stream: [*c]FILE, __format: [*c]const u8, __local_argv: __builtin_va_list) c_int;
pub extern fn vsscanf(noalias __source: [*c]const u8, noalias __format: [*c]const u8, __local_argv: __builtin_va_list) c_int;
pub extern fn vscanf(__format: [*c]const u8, __local_argv: __builtin_va_list) c_int;
pub extern fn _filbuf(_File: [*c]FILE) c_int;
pub extern fn _flsbuf(_Ch: c_int, _File: [*c]FILE) c_int;
pub extern fn _fsopen(_Filename: [*c]const u8, _Mode: [*c]const u8, _ShFlag: c_int) [*c]FILE;
pub extern fn clearerr(_File: [*c]FILE) void;
pub extern fn fclose(_File: [*c]FILE) c_int;
pub extern fn _fcloseall() c_int;
pub extern fn _fdopen(_FileHandle: c_int, _Mode: [*c]const u8) [*c]FILE;
pub extern fn feof(_File: [*c]FILE) c_int;
pub extern fn ferror(_File: [*c]FILE) c_int;
pub extern fn fflush(_File: [*c]FILE) c_int;
pub extern fn fgetc(_File: [*c]FILE) c_int;
pub extern fn _fgetchar() c_int;
pub extern fn fgetpos(noalias _File: [*c]FILE, noalias _Pos: [*c]fpos_t) c_int;
pub extern fn fgetpos64(noalias _File: [*c]FILE, noalias _Pos: [*c]fpos_t) c_int;
pub extern fn fgets(noalias _Buf: [*c]u8, _MaxCount: c_int, noalias _File: [*c]FILE) [*c]u8;
pub extern fn _fileno(_File: [*c]FILE) c_int;
pub extern fn _tempnam(_DirName: [*c]const u8, _FilePrefix: [*c]const u8) [*c]u8;
pub extern fn _flushall() c_int;
pub extern fn fopen(noalias _Filename: [*c]const u8, noalias _Mode: [*c]const u8) [*c]FILE;
pub extern fn fopen64(noalias filename: [*c]const u8, noalias mode: [*c]const u8) [*c]FILE;
pub extern fn fputc(_Ch: c_int, _File: [*c]FILE) c_int;
pub extern fn _fputchar(_Ch: c_int) c_int;
pub extern fn fputs(noalias _Str: [*c]const u8, noalias _File: [*c]FILE) c_int;
pub extern fn fread(noalias _DstBuf: ?*anyopaque, _ElementSize: usize, _Count: usize, noalias _File: [*c]FILE) usize;
pub extern fn freopen(noalias _Filename: [*c]const u8, noalias _Mode: [*c]const u8, noalias _File: [*c]FILE) [*c]FILE;
pub extern fn freopen64(noalias _Filename: [*c]const u8, noalias _Mode: [*c]const u8, noalias _File: [*c]FILE) [*c]FILE;
pub extern fn fsetpos(_File: [*c]FILE, _Pos: [*c]const fpos_t) c_int;
pub extern fn fsetpos64(_File: [*c]FILE, _Pos: [*c]const fpos_t) c_int;
pub extern fn fseek(_File: [*c]FILE, _Offset: c_long, _Origin: c_int) c_int;
pub extern fn ftell(_File: [*c]FILE) c_long;
pub extern fn _fseeki64(_File: [*c]FILE, _Offset: c_longlong, _Origin: c_int) c_int;
pub extern fn _ftelli64(_File: [*c]FILE) c_longlong;
pub extern fn fseeko(_File: [*c]FILE, _Offset: _off_t, _Origin: c_int) c_int;
pub extern fn fseeko64(_File: [*c]FILE, _Offset: _off64_t, _Origin: c_int) c_int;
pub extern fn ftello(_File: [*c]FILE) _off_t;
pub extern fn ftello64(_File: [*c]FILE) _off64_t;
pub extern fn fwrite(noalias _Str: ?*const anyopaque, _Size: usize, _Count: usize, noalias _File: [*c]FILE) usize;
pub extern fn getc(_File: [*c]FILE) c_int;
pub extern fn getchar() c_int;
pub extern fn _getmaxstdio() c_int;
pub extern fn gets(_Buffer: [*c]u8) [*c]u8;
pub extern fn _getw(_File: [*c]FILE) c_int;
pub extern fn perror(_ErrMsg: [*c]const u8) void;
pub extern fn _pclose(_File: [*c]FILE) c_int;
pub extern fn _popen(_Command: [*c]const u8, _Mode: [*c]const u8) [*c]FILE;
pub extern fn putc(_Ch: c_int, _File: [*c]FILE) c_int;
pub extern fn putchar(_Ch: c_int) c_int;
pub extern fn puts(_Str: [*c]const u8) c_int;
pub extern fn _putw(_Word: c_int, _File: [*c]FILE) c_int;
pub extern fn remove(_Filename: [*c]const u8) c_int;
pub extern fn rename(_OldFilename: [*c]const u8, _NewFilename: [*c]const u8) c_int;
pub extern fn _unlink(_Filename: [*c]const u8) c_int;
pub extern fn unlink(_Filename: [*c]const u8) c_int;
pub extern fn rewind(_File: [*c]FILE) void;
pub extern fn _rmtmp() c_int;
pub extern fn setbuf(noalias _File: [*c]FILE, noalias _Buffer: [*c]u8) void;
pub extern fn _setmaxstdio(_Max: c_int) c_int;
pub extern fn _set_output_format(_Format: c_uint) c_uint;
pub extern fn _get_output_format() c_uint;
pub extern fn setvbuf(noalias _File: [*c]FILE, noalias _Buf: [*c]u8, _Mode: c_int, _Size: usize) c_int;
pub extern fn _scprintf(noalias _Format: [*c]const u8, ...) c_int;
pub extern fn _snscanf(noalias _Src: [*c]const u8, _MaxCount: usize, noalias _Format: [*c]const u8, ...) c_int;
pub extern fn _vscprintf(noalias _Format: [*c]const u8, _ArgList: va_list) c_int;
pub extern fn tmpfile() [*c]FILE;
pub extern fn tmpfile64() [*c]FILE;
pub extern fn tmpnam(_Buffer: [*c]u8) [*c]u8;
pub extern fn ungetc(_Ch: c_int, _File: [*c]FILE) c_int;
pub extern fn _vsnprintf(noalias _Dest: [*c]u8, _Count: usize, noalias _Format: [*c]const u8, _Args: va_list) c_int;
pub extern fn _snprintf(noalias _Dest: [*c]u8, _Count: usize, noalias _Format: [*c]const u8, ...) c_int;
pub extern fn vsnprintf(noalias __stream: [*c]u8, __n: usize, noalias __format: [*c]const u8, __local_argv: va_list) c_int;
pub extern fn snprintf(noalias __stream: [*c]u8, __n: usize, noalias __format: [*c]const u8, ...) c_int;
pub extern fn _set_printf_count_output(_Value: c_int) c_int;
pub extern fn _get_printf_count_output() c_int;
pub extern fn __mingw_swscanf(noalias _Src: [*c]const wchar_t, noalias _Format: [*c]const wchar_t, ...) c_int;
pub extern fn __mingw_vswscanf(noalias _Str: [*c]const wchar_t, noalias Format: [*c]const wchar_t, argp: va_list) c_int;
pub extern fn __mingw_wscanf(noalias _Format: [*c]const wchar_t, ...) c_int;
pub extern fn __mingw_vwscanf(noalias Format: [*c]const wchar_t, argp: va_list) c_int;
pub extern fn __mingw_fwscanf(noalias _File: [*c]FILE, noalias _Format: [*c]const wchar_t, ...) c_int;
pub extern fn __mingw_vfwscanf(noalias fp: [*c]FILE, noalias Format: [*c]const wchar_t, argp: va_list) c_int;
pub extern fn __mingw_fwprintf(noalias _File: [*c]FILE, noalias _Format: [*c]const wchar_t, ...) c_int;
pub extern fn __mingw_wprintf(noalias _Format: [*c]const wchar_t, ...) c_int;
pub extern fn __mingw_vfwprintf(noalias _File: [*c]FILE, noalias _Format: [*c]const wchar_t, _ArgList: va_list) c_int;
pub extern fn __mingw_vwprintf(noalias _Format: [*c]const wchar_t, _ArgList: va_list) c_int;
pub extern fn __mingw_snwprintf(noalias s: [*c]wchar_t, n: usize, noalias format: [*c]const wchar_t, ...) c_int;
pub extern fn __mingw_vsnwprintf(noalias [*c]wchar_t, usize, noalias [*c]const wchar_t, va_list) c_int;
pub extern fn __mingw_swprintf(noalias [*c]wchar_t, usize, noalias [*c]const wchar_t, ...) c_int;
pub extern fn __mingw_vswprintf(noalias [*c]wchar_t, usize, noalias [*c]const wchar_t, va_list) c_int;
pub extern fn __ms_swscanf(noalias _Src: [*c]const wchar_t, noalias _Format: [*c]const wchar_t, ...) c_int;
pub extern fn __ms_vswscanf(noalias _Src: [*c]const wchar_t, noalias _Format: [*c]const wchar_t, va_list) c_int;
pub extern fn __ms_wscanf(noalias _Format: [*c]const wchar_t, ...) c_int;
pub extern fn __ms_vwscanf(noalias _Format: [*c]const wchar_t, va_list) c_int;
pub extern fn __ms_fwscanf(noalias _File: [*c]FILE, noalias _Format: [*c]const wchar_t, ...) c_int;
pub extern fn __ms_vfwscanf(noalias _File: [*c]FILE, noalias _Format: [*c]const wchar_t, va_list) c_int;
pub extern fn __ms_fwprintf(noalias _File: [*c]FILE, noalias _Format: [*c]const wchar_t, ...) c_int;
pub extern fn __ms_wprintf(noalias _Format: [*c]const wchar_t, ...) c_int;
pub extern fn __ms_vfwprintf(noalias _File: [*c]FILE, noalias _Format: [*c]const wchar_t, _ArgList: va_list) c_int;
pub extern fn __ms_vwprintf(noalias _Format: [*c]const wchar_t, _ArgList: va_list) c_int;
pub extern fn __ms_swprintf(noalias [*c]wchar_t, usize, noalias [*c]const wchar_t, ...) c_int;
pub extern fn __ms_vswprintf(noalias [*c]wchar_t, usize, noalias [*c]const wchar_t, va_list) c_int;
pub extern fn __ms_snwprintf(noalias [*c]wchar_t, usize, noalias [*c]const wchar_t, ...) c_int;
pub extern fn __ms_vsnwprintf(noalias [*c]wchar_t, usize, noalias [*c]const wchar_t, va_list) c_int;
pub extern fn __stdio_common_vswprintf(options: c_ulonglong, str: [*c]wchar_t, len: usize, format: [*c]const wchar_t, locale: _locale_t, valist: va_list) c_int;
pub extern fn __stdio_common_vfwprintf(options: c_ulonglong, file: [*c]FILE, format: [*c]const wchar_t, locale: _locale_t, valist: va_list) c_int;
pub extern fn __stdio_common_vswscanf(options: c_ulonglong, input: [*c]const wchar_t, length: usize, format: [*c]const wchar_t, locale: _locale_t, valist: va_list) c_int;
pub extern fn __stdio_common_vfwscanf(options: c_ulonglong, file: [*c]FILE, format: [*c]const wchar_t, locale: _locale_t, valist: va_list) c_int;
pub extern fn fwscanf(noalias _File: [*c]FILE, noalias _Format: [*c]const wchar_t, ...) c_int;
pub extern fn swscanf(noalias _Src: [*c]const wchar_t, noalias _Format: [*c]const wchar_t, ...) c_int;
pub extern fn wscanf(noalias _Format: [*c]const wchar_t, ...) c_int;
pub extern fn vfwscanf(__stream: [*c]FILE, __format: [*c]const wchar_t, __local_argv: va_list) c_int;
pub extern fn vswscanf(noalias __source: [*c]const wchar_t, noalias __format: [*c]const wchar_t, __local_argv: va_list) c_int;
pub extern fn vwscanf(__format: [*c]const wchar_t, __local_argv: va_list) c_int;
pub extern fn fwprintf(noalias _File: [*c]FILE, noalias _Format: [*c]const wchar_t, ...) c_int;
pub extern fn wprintf(noalias _Format: [*c]const wchar_t, ...) c_int;
pub extern fn vfwprintf(noalias _File: [*c]FILE, noalias _Format: [*c]const wchar_t, _ArgList: va_list) c_int;
pub extern fn vwprintf(noalias _Format: [*c]const wchar_t, _ArgList: va_list) c_int;
pub extern fn swprintf(noalias _Dest: [*c]wchar_t, _Count: usize, noalias _Format: [*c]const wchar_t, ...) c_int;
pub extern fn vswprintf(noalias _Dest: [*c]wchar_t, _Count: usize, noalias _Format: [*c]const wchar_t, _Args: va_list) c_int;
pub extern fn snwprintf(noalias s: [*c]wchar_t, n: usize, noalias format: [*c]const wchar_t, ...) c_int;
pub extern fn vsnwprintf(noalias s: [*c]wchar_t, n: usize, noalias format: [*c]const wchar_t, arg: va_list) c_int;
pub extern fn _wfsopen(_Filename: [*c]const wchar_t, _Mode: [*c]const wchar_t, _ShFlag: c_int) [*c]FILE;
pub extern fn fgetwc(_File: [*c]FILE) wint_t;
pub extern fn _fgetwchar() wint_t;
pub extern fn fputwc(_Ch: wchar_t, _File: [*c]FILE) wint_t;
pub extern fn _fputwchar(_Ch: wchar_t) wint_t;
pub extern fn getwc(_File: [*c]FILE) wint_t;
pub extern fn getwchar() wint_t;
pub extern fn putwc(_Ch: wchar_t, _File: [*c]FILE) wint_t;
pub extern fn putwchar(_Ch: wchar_t) wint_t;
pub extern fn ungetwc(_Ch: wint_t, _File: [*c]FILE) wint_t;
pub extern fn fgetws(noalias _Dst: [*c]wchar_t, _SizeInWords: c_int, noalias _File: [*c]FILE) [*c]wchar_t;
pub extern fn fputws(noalias _Str: [*c]const wchar_t, noalias _File: [*c]FILE) c_int;
pub extern fn _getws(_String: [*c]wchar_t) [*c]wchar_t;
pub extern fn _putws(_Str: [*c]const wchar_t) c_int;
pub extern fn _scwprintf(noalias _Format: [*c]const wchar_t, ...) c_int;
pub extern fn _snwprintf(noalias _Dest: [*c]wchar_t, _Count: usize, noalias _Format: [*c]const wchar_t, ...) c_int;
pub extern fn _vsnwprintf(noalias _Dest: [*c]wchar_t, _Count: usize, noalias _Format: [*c]const wchar_t, _Args: va_list) c_int;
pub extern fn _vscwprintf(noalias _Format: [*c]const wchar_t, _ArgList: va_list) c_int;
pub extern fn _swprintf(noalias _Dest: [*c]wchar_t, noalias _Format: [*c]const wchar_t, ...) c_int;
pub extern fn _vswprintf(noalias _Dest: [*c]wchar_t, noalias _Format: [*c]const wchar_t, _Args: va_list) c_int;
pub extern fn _wtempnam(_Directory: [*c]const wchar_t, _FilePrefix: [*c]const wchar_t) [*c]wchar_t;
pub extern fn _snwscanf(noalias _Src: [*c]const wchar_t, _MaxCount: usize, noalias _Format: [*c]const wchar_t, ...) c_int;
pub extern fn _wfdopen(_FileHandle: c_int, _Mode: [*c]const wchar_t) [*c]FILE;
pub extern fn _wfopen(noalias _Filename: [*c]const wchar_t, noalias _Mode: [*c]const wchar_t) [*c]FILE;
pub extern fn _wfreopen(noalias _Filename: [*c]const wchar_t, noalias _Mode: [*c]const wchar_t, noalias _OldFile: [*c]FILE) [*c]FILE;
pub extern fn _wperror(_ErrMsg: [*c]const wchar_t) void;
pub extern fn _wpopen(_Command: [*c]const wchar_t, _Mode: [*c]const wchar_t) [*c]FILE;
pub extern fn _wremove(_Filename: [*c]const wchar_t) c_int;
pub extern fn _wtmpnam(_Buffer: [*c]wchar_t) [*c]wchar_t;
pub extern fn _fgetwc_nolock(_File: [*c]FILE) wint_t;
pub extern fn _fputwc_nolock(_Ch: wchar_t, _File: [*c]FILE) wint_t;
pub extern fn _ungetwc_nolock(_Ch: wint_t, _File: [*c]FILE) wint_t;
pub extern fn _fgetc_nolock(_File: [*c]FILE) c_int;
pub extern fn _fputc_nolock(_Char: c_int, _File: [*c]FILE) c_int;
pub extern fn _getc_nolock(_File: [*c]FILE) c_int;
pub extern fn _putc_nolock(_Char: c_int, _File: [*c]FILE) c_int;
pub extern fn _lock_file(_File: [*c]FILE) void;
pub extern fn _unlock_file(_File: [*c]FILE) void;
pub extern fn _fclose_nolock(_File: [*c]FILE) c_int;
pub extern fn _fflush_nolock(_File: [*c]FILE) c_int;
pub extern fn _fread_nolock(noalias _DstBuf: ?*anyopaque, _ElementSize: usize, _Count: usize, noalias _File: [*c]FILE) usize;
pub extern fn _fseek_nolock(_File: [*c]FILE, _Offset: c_long, _Origin: c_int) c_int;
pub extern fn _ftell_nolock(_File: [*c]FILE) c_long;
pub extern fn _fseeki64_nolock(_File: [*c]FILE, _Offset: c_longlong, _Origin: c_int) c_int;
pub extern fn _ftelli64_nolock(_File: [*c]FILE) c_longlong;
pub extern fn _fwrite_nolock(noalias _DstBuf: ?*const anyopaque, _Size: usize, _Count: usize, noalias _File: [*c]FILE) usize;
pub extern fn _ungetc_nolock(_Ch: c_int, _File: [*c]FILE) c_int;
pub extern fn tempnam(_Directory: [*c]const u8, _FilePrefix: [*c]const u8) [*c]u8;
pub extern fn fcloseall() c_int;
pub extern fn fdopen(_FileHandle: c_int, _Format: [*c]const u8) [*c]FILE;
pub extern fn fgetchar() c_int;
pub extern fn fileno(_File: [*c]FILE) c_int;
pub extern fn flushall() c_int;
pub extern fn fputchar(_Ch: c_int) c_int;
pub extern fn getw(_File: [*c]FILE) c_int;
pub extern fn putw(_Ch: c_int, _File: [*c]FILE) c_int;
pub extern fn rmtmp() c_int;
pub extern fn __mingw_str_wide_utf8(wptr: [*c]const wchar_t, mbptr: [*c][*c]u8, buflen: [*c]usize) c_int;
pub extern fn __mingw_str_utf8_wide(mbptr: [*c]const u8, wptr: [*c][*c]wchar_t, buflen: [*c]usize) c_int;
pub extern fn __mingw_str_free(ptr: ?*anyopaque) void;
pub extern fn _wspawnl(_Mode: c_int, _Filename: [*c]const wchar_t, _ArgList: [*c]const wchar_t, ...) isize;
pub extern fn _wspawnle(_Mode: c_int, _Filename: [*c]const wchar_t, _ArgList: [*c]const wchar_t, ...) isize;
pub extern fn _wspawnlp(_Mode: c_int, _Filename: [*c]const wchar_t, _ArgList: [*c]const wchar_t, ...) isize;
pub extern fn _wspawnlpe(_Mode: c_int, _Filename: [*c]const wchar_t, _ArgList: [*c]const wchar_t, ...) isize;
pub extern fn _wspawnv(_Mode: c_int, _Filename: [*c]const wchar_t, _ArgList: [*c]const [*c]const wchar_t) isize;
pub extern fn _wspawnve(_Mode: c_int, _Filename: [*c]const wchar_t, _ArgList: [*c]const [*c]const wchar_t, _Env: [*c]const [*c]const wchar_t) isize;
pub extern fn _wspawnvp(_Mode: c_int, _Filename: [*c]const wchar_t, _ArgList: [*c]const [*c]const wchar_t) isize;
pub extern fn _wspawnvpe(_Mode: c_int, _Filename: [*c]const wchar_t, _ArgList: [*c]const [*c]const wchar_t, _Env: [*c]const [*c]const wchar_t) isize;
pub extern fn _spawnv(_Mode: c_int, _Filename: [*c]const u8, _ArgList: [*c]const [*c]const u8) isize;
pub extern fn _spawnve(_Mode: c_int, _Filename: [*c]const u8, _ArgList: [*c]const [*c]const u8, _Env: [*c]const [*c]const u8) isize;
pub extern fn _spawnvp(_Mode: c_int, _Filename: [*c]const u8, _ArgList: [*c]const [*c]const u8) isize;
pub extern fn _spawnvpe(_Mode: c_int, _Filename: [*c]const u8, _ArgList: [*c]const [*c]const u8, _Env: [*c]const [*c]const u8) isize;
pub extern fn clearerr_s(_File: [*c]FILE) errno_t;
pub extern fn fread_s(_DstBuf: ?*anyopaque, _DstSize: usize, _ElementSize: usize, _Count: usize, _File: [*c]FILE) usize;
pub extern fn __stdio_common_vsprintf_s(_Options: c_ulonglong, _Str: [*c]u8, _Len: usize, _Format: [*c]const u8, _Locale: _locale_t, _ArgList: va_list) c_int;
pub extern fn __stdio_common_vsprintf_p(_Options: c_ulonglong, _Str: [*c]u8, _Len: usize, _Format: [*c]const u8, _Locale: _locale_t, _ArgList: va_list) c_int;
pub extern fn __stdio_common_vsnprintf_s(_Options: c_ulonglong, _Str: [*c]u8, _Len: usize, _MaxCount: usize, _Format: [*c]const u8, _Locale: _locale_t, _ArgList: va_list) c_int;
pub extern fn __stdio_common_vfprintf_s(_Options: c_ulonglong, _File: [*c]FILE, _Format: [*c]const u8, _Locale: _locale_t, _ArgList: va_list) c_int;
pub extern fn __stdio_common_vfprintf_p(_Options: c_ulonglong, _File: [*c]FILE, _Format: [*c]const u8, _Locale: _locale_t, _ArgList: va_list) c_int;
pub fn _vfscanf_s_l(arg__File: [*c]FILE, arg__Format: [*c]const u8, arg__Locale: _locale_t, arg__ArgList: va_list) callconv(.c) c_int {
    var _File = arg__File;
    _ = &_File;
    var _Format = arg__Format;
    _ = &_Format;
    var _Locale = arg__Locale;
    _ = &_Locale;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return __stdio_common_vfscanf(_CRT_INTERNAL_SCANF_SECURECRT, _File, _Format, _Locale, _ArgList);
}
pub fn vfscanf_s(arg__File: [*c]FILE, arg__Format: [*c]const u8, arg__ArgList: va_list) callconv(.c) c_int {
    var _File = arg__File;
    _ = &_File;
    var _Format = arg__Format;
    _ = &_Format;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return _vfscanf_s_l(_File, _Format, null, _ArgList);
}
pub fn _vscanf_s_l(arg__Format: [*c]const u8, arg__Locale: _locale_t, arg__ArgList: va_list) callconv(.c) c_int {
    var _Format = arg__Format;
    _ = &_Format;
    var _Locale = arg__Locale;
    _ = &_Locale;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return _vfscanf_s_l(__acrt_iob_func(0), _Format, _Locale, _ArgList);
}
pub fn vscanf_s(arg__Format: [*c]const u8, arg__ArgList: va_list) callconv(.c) c_int {
    var _Format = arg__Format;
    _ = &_Format;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return _vfscanf_s_l(__acrt_iob_func(0), _Format, null, _ArgList);
}
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:60:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _fscanf_s_l(_File: [*c]FILE, _Format: [*c]const u8, _Locale: _locale_t, ...) c_int;
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:70:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn fscanf_s(_File: [*c]FILE, _Format: [*c]const u8, ...) c_int;
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:80:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _scanf_s_l(_Format: [*c]const u8, _Locale: _locale_t, ...) c_int;
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:90:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn scanf_s(_Format: [*c]const u8, ...) c_int;
pub fn _vfscanf_l(arg__File: [*c]FILE, arg__Format: [*c]const u8, arg__Locale: _locale_t, arg__ArgList: va_list) callconv(.c) c_int {
    var _File = arg__File;
    _ = &_File;
    var _Format = arg__Format;
    _ = &_Format;
    var _Locale = arg__Locale;
    _ = &_Locale;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return __stdio_common_vfscanf(0, _File, _Format, _Locale, _ArgList);
}
pub fn _vscanf_l(arg__Format: [*c]const u8, arg__Locale: _locale_t, arg__ArgList: va_list) callconv(.c) c_int {
    var _Format = arg__Format;
    _ = &_Format;
    var _Locale = arg__Locale;
    _ = &_Locale;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return _vfscanf_l(__acrt_iob_func(0), _Format, _Locale, _ArgList);
}
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:110:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _fscanf_l(_File: [*c]FILE, _Format: [*c]const u8, _Locale: _locale_t, ...) c_int;
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:119:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _scanf_l(_Format: [*c]const u8, _Locale: _locale_t, ...) c_int;
pub fn _vsscanf_s_l(arg__Src: [*c]const u8, arg__Format: [*c]const u8, arg__Locale: _locale_t, arg__ArgList: va_list) callconv(.c) c_int {
    var _Src = arg__Src;
    _ = &_Src;
    var _Format = arg__Format;
    _ = &_Format;
    var _Locale = arg__Locale;
    _ = &_Locale;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return __stdio_common_vsscanf(_CRT_INTERNAL_SCANF_SECURECRT, _Src, @bitCast(@as(c_longlong, -@as(c_int, 1))), _Format, _Locale, _ArgList);
}
pub fn vsscanf_s(arg__Src: [*c]const u8, arg__Format: [*c]const u8, arg__ArgList: va_list) callconv(.c) c_int {
    var _Src = arg__Src;
    _ = &_Src;
    var _Format = arg__Format;
    _ = &_Format;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return _vsscanf_s_l(_Src, _Format, null, _ArgList);
}
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:137:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _sscanf_s_l(_Src: [*c]const u8, _Format: [*c]const u8, _Locale: _locale_t, ...) c_int;
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:146:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn sscanf_s(_Src: [*c]const u8, _Format: [*c]const u8, ...) c_int;
pub fn _vsscanf_l(arg__Src: [*c]const u8, arg__Format: [*c]const u8, arg__Locale: _locale_t, arg__ArgList: va_list) callconv(.c) c_int {
    var _Src = arg__Src;
    _ = &_Src;
    var _Format = arg__Format;
    _ = &_Format;
    var _Locale = arg__Locale;
    _ = &_Locale;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return __stdio_common_vsscanf(0, _Src, @bitCast(@as(c_longlong, -@as(c_int, 1))), _Format, _Locale, _ArgList);
}
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:160:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _sscanf_l(_Src: [*c]const u8, _Format: [*c]const u8, _Locale: _locale_t, ...) c_int;
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:171:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _snscanf_s_l(_Src: [*c]const u8, _MaxCount: usize, _Format: [*c]const u8, _Locale: _locale_t, ...) c_int;
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:180:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _snscanf_s(_Src: [*c]const u8, _MaxCount: usize, _Format: [*c]const u8, ...) c_int;
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:191:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _snscanf_l(_Src: [*c]const u8, _MaxCount: usize, _Format: [*c]const u8, _Locale: _locale_t, ...) c_int;
pub fn _vfprintf_s_l(arg__File: [*c]FILE, arg__Format: [*c]const u8, arg__Locale: _locale_t, arg__ArgList: va_list) callconv(.c) c_int {
    var _File = arg__File;
    _ = &_File;
    var _Format = arg__Format;
    _ = &_Format;
    var _Locale = arg__Locale;
    _ = &_Locale;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return __stdio_common_vfprintf_s(__local_stdio_printf_options().*, _File, _Format, _Locale, _ArgList);
}
pub fn vfprintf_s(arg__File: [*c]FILE, arg__Format: [*c]const u8, arg__ArgList: va_list) callconv(.c) c_int {
    var _File = arg__File;
    _ = &_File;
    var _Format = arg__Format;
    _ = &_Format;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return _vfprintf_s_l(_File, _Format, null, _ArgList);
}
pub fn _vprintf_s_l(arg__Format: [*c]const u8, arg__Locale: _locale_t, arg__ArgList: va_list) callconv(.c) c_int {
    var _Format = arg__Format;
    _ = &_Format;
    var _Locale = arg__Locale;
    _ = &_Locale;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return _vfprintf_s_l(__acrt_iob_func(1), _Format, _Locale, _ArgList);
}
pub fn vprintf_s(arg__Format: [*c]const u8, arg__ArgList: va_list) callconv(.c) c_int {
    var _Format = arg__Format;
    _ = &_Format;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return _vfprintf_s_l(__acrt_iob_func(1), _Format, null, _ArgList);
}
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:218:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _fprintf_s_l(_File: [*c]FILE, _Format: [*c]const u8, _Locale: _locale_t, ...) c_int;
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:227:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _printf_s_l(_Format: [*c]const u8, _Locale: _locale_t, ...) c_int;
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:236:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn fprintf_s(_File: [*c]FILE, _Format: [*c]const u8, ...) c_int;
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:245:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn printf_s(_Format: [*c]const u8, ...) c_int;
pub fn _vsnprintf_c_l(arg__DstBuf: [*c]u8, arg__MaxCount: usize, arg__Format: [*c]const u8, arg__Locale: _locale_t, arg__ArgList: va_list) callconv(.c) c_int {
    var _DstBuf = arg__DstBuf;
    _ = &_DstBuf;
    var _MaxCount = arg__MaxCount;
    _ = &_MaxCount;
    var _Format = arg__Format;
    _ = &_Format;
    var _Locale = arg__Locale;
    _ = &_Locale;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return __stdio_common_vsprintf(__local_stdio_printf_options().*, _DstBuf, _MaxCount, _Format, _Locale, _ArgList);
}
pub fn _vsnprintf_c(arg__DstBuf: [*c]u8, arg__MaxCount: usize, arg__Format: [*c]const u8, arg__ArgList: va_list) callconv(.c) c_int {
    var _DstBuf = arg__DstBuf;
    _ = &_DstBuf;
    var _MaxCount = arg__MaxCount;
    _ = &_MaxCount;
    var _Format = arg__Format;
    _ = &_Format;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return _vsnprintf_c_l(_DstBuf, _MaxCount, _Format, null, _ArgList);
}
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:263:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _snprintf_c_l(_DstBuf: [*c]u8, _MaxCount: usize, _Format: [*c]const u8, _Locale: _locale_t, ...) c_int;
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:272:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _snprintf_c(_DstBuf: [*c]u8, _MaxCount: usize, _Format: [*c]const u8, ...) c_int;
pub fn _vsnprintf_s_l(arg__DstBuf: [*c]u8, arg__DstSize: usize, arg__MaxCount: usize, arg__Format: [*c]const u8, arg__Locale: _locale_t, arg__ArgList: va_list) callconv(.c) c_int {
    var _DstBuf = arg__DstBuf;
    _ = &_DstBuf;
    var _DstSize = arg__DstSize;
    _ = &_DstSize;
    var _MaxCount = arg__MaxCount;
    _ = &_MaxCount;
    var _Format = arg__Format;
    _ = &_Format;
    var _Locale = arg__Locale;
    _ = &_Locale;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return __stdio_common_vsnprintf_s(__local_stdio_printf_options().*, _DstBuf, _DstSize, _MaxCount, _Format, _Locale, _ArgList);
}
pub fn vsnprintf_s(arg__DstBuf: [*c]u8, arg__DstSize: usize, arg__MaxCount: usize, arg__Format: [*c]const u8, arg__ArgList: va_list) callconv(.c) c_int {
    var _DstBuf = arg__DstBuf;
    _ = &_DstBuf;
    var _DstSize = arg__DstSize;
    _ = &_DstSize;
    var _MaxCount = arg__MaxCount;
    _ = &_MaxCount;
    var _Format = arg__Format;
    _ = &_Format;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return _vsnprintf_s_l(_DstBuf, _DstSize, _MaxCount, _Format, null, _ArgList);
}
pub fn _vsnprintf_s(arg__DstBuf: [*c]u8, arg__DstSize: usize, arg__MaxCount: usize, arg__Format: [*c]const u8, arg__ArgList: va_list) callconv(.c) c_int {
    var _DstBuf = arg__DstBuf;
    _ = &_DstBuf;
    var _DstSize = arg__DstSize;
    _ = &_DstSize;
    var _MaxCount = arg__MaxCount;
    _ = &_MaxCount;
    var _Format = arg__Format;
    _ = &_Format;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return _vsnprintf_s_l(_DstBuf, _DstSize, _MaxCount, _Format, null, _ArgList);
}
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:294:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _snprintf_s_l(_DstBuf: [*c]u8, _DstSize: usize, _MaxCount: usize, _Format: [*c]const u8, _Locale: _locale_t, ...) c_int;
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:303:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _snprintf_s(_DstBuf: [*c]u8, _DstSize: usize, _MaxCount: usize, _Format: [*c]const u8, ...) c_int;
pub fn _vsprintf_s_l(arg__DstBuf: [*c]u8, arg__DstSize: usize, arg__Format: [*c]const u8, arg__Locale: _locale_t, arg__ArgList: va_list) callconv(.c) c_int {
    var _DstBuf = arg__DstBuf;
    _ = &_DstBuf;
    var _DstSize = arg__DstSize;
    _ = &_DstSize;
    var _Format = arg__Format;
    _ = &_Format;
    var _Locale = arg__Locale;
    _ = &_Locale;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return __stdio_common_vsprintf_s(__local_stdio_printf_options().*, _DstBuf, _DstSize, _Format, _Locale, _ArgList);
}
pub fn vsprintf_s(arg__DstBuf: [*c]u8, arg__Size: usize, arg__Format: [*c]const u8, arg__ArgList: va_list) callconv(.c) c_int {
    var _DstBuf = arg__DstBuf;
    _ = &_DstBuf;
    var _Size = arg__Size;
    _ = &_Size;
    var _Format = arg__Format;
    _ = &_Format;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return _vsprintf_s_l(_DstBuf, _Size, _Format, null, _ArgList);
}
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:321:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _sprintf_s_l(_DstBuf: [*c]u8, _DstSize: usize, _Format: [*c]const u8, _Locale: _locale_t, ...) c_int;
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:330:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn sprintf_s(_DstBuf: [*c]u8, _DstSize: usize, _Format: [*c]const u8, ...) c_int;
pub fn _vfprintf_p_l(arg__File: [*c]FILE, arg__Format: [*c]const u8, arg__Locale: _locale_t, arg__ArgList: va_list) callconv(.c) c_int {
    var _File = arg__File;
    _ = &_File;
    var _Format = arg__Format;
    _ = &_Format;
    var _Locale = arg__Locale;
    _ = &_Locale;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return __stdio_common_vfprintf_p(__local_stdio_printf_options().*, _File, _Format, _Locale, _ArgList);
}
pub fn _vfprintf_p(arg__File: [*c]FILE, arg__Format: [*c]const u8, arg__ArgList: va_list) callconv(.c) c_int {
    var _File = arg__File;
    _ = &_File;
    var _Format = arg__Format;
    _ = &_Format;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return _vfprintf_p_l(_File, _Format, null, _ArgList);
}
pub fn _vprintf_p_l(arg__Format: [*c]const u8, arg__Locale: _locale_t, arg__ArgList: va_list) callconv(.c) c_int {
    var _Format = arg__Format;
    _ = &_Format;
    var _Locale = arg__Locale;
    _ = &_Locale;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return _vfprintf_p_l(__acrt_iob_func(1), _Format, _Locale, _ArgList);
}
pub fn _vprintf_p(arg__Format: [*c]const u8, arg__ArgList: va_list) callconv(.c) c_int {
    var _Format = arg__Format;
    _ = &_Format;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return _vfprintf_p_l(__acrt_iob_func(1), _Format, null, _ArgList);
}
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:356:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _fprintf_p_l(_File: [*c]FILE, _Format: [*c]const u8, _Locale: _locale_t, ...) c_int;
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:365:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _fprintf_p(_File: [*c]FILE, _Format: [*c]const u8, ...) c_int;
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:374:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _printf_p_l(_Format: [*c]const u8, _Locale: _locale_t, ...) c_int;
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:383:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _printf_p(_Format: [*c]const u8, ...) c_int;
pub fn _vsprintf_p_l(arg__DstBuf: [*c]u8, arg__MaxCount: usize, arg__Format: [*c]const u8, arg__Locale: _locale_t, arg__ArgList: va_list) callconv(.c) c_int {
    var _DstBuf = arg__DstBuf;
    _ = &_DstBuf;
    var _MaxCount = arg__MaxCount;
    _ = &_MaxCount;
    var _Format = arg__Format;
    _ = &_Format;
    var _Locale = arg__Locale;
    _ = &_Locale;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return __stdio_common_vsprintf_p(__local_stdio_printf_options().*, _DstBuf, _MaxCount, _Format, _Locale, _ArgList);
}
pub fn _vsprintf_p(arg__Dst: [*c]u8, arg__MaxCount: usize, arg__Format: [*c]const u8, arg__ArgList: va_list) callconv(.c) c_int {
    var _Dst = arg__Dst;
    _ = &_Dst;
    var _MaxCount = arg__MaxCount;
    _ = &_MaxCount;
    var _Format = arg__Format;
    _ = &_Format;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return _vsprintf_p_l(_Dst, _MaxCount, _Format, null, _ArgList);
}
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:401:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _sprintf_p_l(_DstBuf: [*c]u8, _MaxCount: usize, _Format: [*c]const u8, _Locale: _locale_t, ...) c_int;
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:410:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _sprintf_p(_Dst: [*c]u8, _MaxCount: usize, _Format: [*c]const u8, ...) c_int;
pub fn _vscprintf_p_l(arg__Format: [*c]const u8, arg__Locale: _locale_t, arg__ArgList: va_list) callconv(.c) c_int {
    var _Format = arg__Format;
    _ = &_Format;
    var _Locale = arg__Locale;
    _ = &_Locale;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return __stdio_common_vsprintf_p(_CRT_INTERNAL_PRINTF_STANDARD_SNPRINTF_BEHAVIOR, null, 0, _Format, _Locale, _ArgList);
}
pub fn _vscprintf_p(arg__Format: [*c]const u8, arg__ArgList: va_list) callconv(.c) c_int {
    var _Format = arg__Format;
    _ = &_Format;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return _vscprintf_p_l(_Format, null, _ArgList);
}
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:428:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _scprintf_p_l(_Format: [*c]const u8, _Locale: _locale_t, ...) c_int;
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:437:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _scprintf_p(_Format: [*c]const u8, ...) c_int;
pub fn _vfprintf_l(arg__File: [*c]FILE, arg__Format: [*c]const u8, arg__Locale: _locale_t, arg__ArgList: va_list) callconv(.c) c_int {
    var _File = arg__File;
    _ = &_File;
    var _Format = arg__Format;
    _ = &_Format;
    var _Locale = arg__Locale;
    _ = &_Locale;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return __stdio_common_vfprintf(__local_stdio_printf_options().*, _File, _Format, _Locale, _ArgList);
}
pub fn _vprintf_l(arg__Format: [*c]const u8, arg__Locale: _locale_t, arg__ArgList: va_list) callconv(.c) c_int {
    var _Format = arg__Format;
    _ = &_Format;
    var _Locale = arg__Locale;
    _ = &_Locale;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return _vfprintf_l(__acrt_iob_func(1), _Format, _Locale, _ArgList);
}
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:455:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _fprintf_l(_File: [*c]FILE, _Format: [*c]const u8, _Locale: _locale_t, ...) c_int;
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:464:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _printf_l(_Format: [*c]const u8, _Locale: _locale_t, ...) c_int;
pub fn _vsnprintf_l(arg__DstBuf: [*c]u8, arg__MaxCount: usize, arg__Format: [*c]const u8, arg__Locale: _locale_t, arg__ArgList: va_list) callconv(.c) c_int {
    var _DstBuf = arg__DstBuf;
    _ = &_DstBuf;
    var _MaxCount = arg__MaxCount;
    _ = &_MaxCount;
    var _Format = arg__Format;
    _ = &_Format;
    var _Locale = arg__Locale;
    _ = &_Locale;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return __stdio_common_vsprintf(_CRT_INTERNAL_PRINTF_LEGACY_VSPRINTF_NULL_TERMINATION, _DstBuf, _MaxCount, _Format, _Locale, _ArgList);
}
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:478:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _snprintf_l(_DstBuf: [*c]u8, _MaxCount: usize, _Format: [*c]const u8, _Locale: _locale_t, ...) c_int;
pub fn _vsprintf_l(arg__DstBuf: [*c]u8, arg__Format: [*c]const u8, arg__Locale: _locale_t, arg__ArgList: va_list) callconv(.c) c_int {
    var _DstBuf = arg__DstBuf;
    _ = &_DstBuf;
    var _Format = arg__Format;
    _ = &_Format;
    var _Locale = arg__Locale;
    _ = &_Locale;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return _vsnprintf_l(_DstBuf, @bitCast(@as(c_longlong, -@as(c_int, 1))), _Format, _Locale, _ArgList);
}
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:491:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _sprintf_l(_DstBuf: [*c]u8, _Format: [*c]const u8, _Locale: _locale_t, ...) c_int;
pub fn _vscprintf_l(arg__Format: [*c]const u8, arg__Locale: _locale_t, arg__ArgList: va_list) callconv(.c) c_int {
    var _Format = arg__Format;
    _ = &_Format;
    var _Locale = arg__Locale;
    _ = &_Locale;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return __stdio_common_vsprintf(_CRT_INTERNAL_PRINTF_STANDARD_SNPRINTF_BEHAVIOR, null, 0, _Format, _Locale, _ArgList);
}
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:505:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _scprintf_l(_Format: [*c]const u8, _Locale: _locale_t, ...) c_int;
pub extern fn fopen_s(_File: [*c][*c]FILE, _Filename: [*c]const u8, _Mode: [*c]const u8) errno_t;
pub extern fn freopen_s(_File: [*c][*c]FILE, _Filename: [*c]const u8, _Mode: [*c]const u8, _Stream: [*c]FILE) errno_t;
pub extern fn gets_s([*c]u8, rsize_t) [*c]u8;
pub extern fn tmpfile_s(_File: [*c][*c]FILE) errno_t;
pub extern fn tmpnam_s([*c]u8, rsize_t) errno_t;
pub extern fn _getws_s(_Str: [*c]wchar_t, _SizeInWords: usize) [*c]wchar_t;
pub extern fn __stdio_common_vswprintf_s(_Options: c_ulonglong, _Str: [*c]wchar_t, _Len: usize, _Format: [*c]const wchar_t, _Locale: _locale_t, _ArgList: va_list) c_int;
pub extern fn __stdio_common_vsnwprintf_s(_Options: c_ulonglong, _Str: [*c]wchar_t, _Len: usize, _MaxCount: usize, _Format: [*c]const wchar_t, _Locale: _locale_t, _ArgList: va_list) c_int;
pub extern fn __stdio_common_vfwprintf_s(_Options: c_ulonglong, _File: [*c]FILE, _Format: [*c]const wchar_t, _Locale: _locale_t, _ArgList: va_list) c_int;
pub fn _vfwscanf_s_l(arg__File: [*c]FILE, arg__Format: [*c]const wchar_t, arg__Locale: _locale_t, arg__ArgList: va_list) callconv(.c) c_int {
    var _File = arg__File;
    _ = &_File;
    var _Format = arg__Format;
    _ = &_Format;
    var _Locale = arg__Locale;
    _ = &_Locale;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return __stdio_common_vfwscanf(__local_stdio_scanf_options().* | _CRT_INTERNAL_SCANF_SECURECRT, _File, _Format, _Locale, _ArgList);
}
pub fn vfwscanf_s(arg__File: [*c]FILE, arg__Format: [*c]const wchar_t, arg__ArgList: va_list) callconv(.c) c_int {
    var _File = arg__File;
    _ = &_File;
    var _Format = arg__Format;
    _ = &_Format;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return _vfwscanf_s_l(_File, _Format, null, _ArgList);
}
pub fn _vwscanf_s_l(arg__Format: [*c]const wchar_t, arg__Locale: _locale_t, arg__ArgList: va_list) callconv(.c) c_int {
    var _Format = arg__Format;
    _ = &_Format;
    var _Locale = arg__Locale;
    _ = &_Locale;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return _vfwscanf_s_l(__acrt_iob_func(0), _Format, _Locale, _ArgList);
}
pub fn vwscanf_s(arg__Format: [*c]const wchar_t, arg__ArgList: va_list) callconv(.c) c_int {
    var _Format = arg__Format;
    _ = &_Format;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return _vfwscanf_s_l(__acrt_iob_func(0), _Format, null, _ArgList);
}
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:631:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _fwscanf_s_l(_File: [*c]FILE, _Format: [*c]const wchar_t, _Locale: _locale_t, ...) c_int;
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:641:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn fwscanf_s(_File: [*c]FILE, _Format: [*c]const wchar_t, ...) c_int;
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:651:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _wscanf_s_l(_Format: [*c]const wchar_t, _Locale: _locale_t, ...) c_int;
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:661:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn wscanf_s(_Format: [*c]const wchar_t, ...) c_int;
pub fn _vswscanf_s_l(arg__Src: [*c]const wchar_t, arg__Format: [*c]const wchar_t, arg__Locale: _locale_t, arg__ArgList: va_list) callconv(.c) c_int {
    var _Src = arg__Src;
    _ = &_Src;
    var _Format = arg__Format;
    _ = &_Format;
    var _Locale = arg__Locale;
    _ = &_Locale;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return __stdio_common_vswscanf(__local_stdio_scanf_options().* | _CRT_INTERNAL_SCANF_SECURECRT, _Src, @bitCast(@as(c_longlong, -@as(c_int, 1))), _Format, _Locale, _ArgList);
}
pub fn vswscanf_s(arg__Src: [*c]const wchar_t, arg__Format: [*c]const wchar_t, arg__ArgList: va_list) callconv(.c) c_int {
    var _Src = arg__Src;
    _ = &_Src;
    var _Format = arg__Format;
    _ = &_Format;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return _vswscanf_s_l(_Src, _Format, null, _ArgList);
}
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:681:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _swscanf_s_l(_Src: [*c]const wchar_t, _Format: [*c]const wchar_t, _Locale: _locale_t, ...) c_int;
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:690:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn swscanf_s(_Src: [*c]const wchar_t, _Format: [*c]const wchar_t, ...) c_int;
pub fn _vsnwscanf_s_l(arg__Src: [*c]const wchar_t, arg__MaxCount: usize, arg__Format: [*c]const wchar_t, arg__Locale: _locale_t, arg__ArgList: va_list) callconv(.c) c_int {
    var _Src = arg__Src;
    _ = &_Src;
    var _MaxCount = arg__MaxCount;
    _ = &_MaxCount;
    var _Format = arg__Format;
    _ = &_Format;
    var _Locale = arg__Locale;
    _ = &_Locale;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return __stdio_common_vswscanf(__local_stdio_scanf_options().* | _CRT_INTERNAL_SCANF_SECURECRT, _Src, _MaxCount, _Format, _Locale, _ArgList);
}
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:704:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _snwscanf_s_l(_Src: [*c]const wchar_t, _MaxCount: usize, _Format: [*c]const wchar_t, _Locale: _locale_t, ...) c_int;
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:713:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _snwscanf_s(_Src: [*c]const wchar_t, _MaxCount: usize, _Format: [*c]const wchar_t, ...) c_int;
pub fn _vfwprintf_s_l(arg__File: [*c]FILE, arg__Format: [*c]const wchar_t, arg__Locale: _locale_t, arg__ArgList: va_list) callconv(.c) c_int {
    var _File = arg__File;
    _ = &_File;
    var _Format = arg__Format;
    _ = &_Format;
    var _Locale = arg__Locale;
    _ = &_Locale;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return __stdio_common_vfwprintf_s(__local_stdio_printf_options().*, _File, _Format, _Locale, _ArgList);
}
pub fn _vwprintf_s_l(arg__Format: [*c]const wchar_t, arg__Locale: _locale_t, arg__ArgList: va_list) callconv(.c) c_int {
    var _Format = arg__Format;
    _ = &_Format;
    var _Locale = arg__Locale;
    _ = &_Locale;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return _vfwprintf_s_l(__acrt_iob_func(1), _Format, _Locale, _ArgList);
}
pub fn vfwprintf_s(arg__File: [*c]FILE, arg__Format: [*c]const wchar_t, arg__ArgList: va_list) callconv(.c) c_int {
    var _File = arg__File;
    _ = &_File;
    var _Format = arg__Format;
    _ = &_Format;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return _vfwprintf_s_l(_File, _Format, null, _ArgList);
}
pub fn vwprintf_s(arg__Format: [*c]const wchar_t, arg__ArgList: va_list) callconv(.c) c_int {
    var _Format = arg__Format;
    _ = &_Format;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return _vfwprintf_s_l(__acrt_iob_func(1), _Format, null, _ArgList);
}
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:739:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _fwprintf_s_l(_File: [*c]FILE, _Format: [*c]const wchar_t, _Locale: _locale_t, ...) c_int;
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:748:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _wprintf_s_l(_Format: [*c]const wchar_t, _Locale: _locale_t, ...) c_int;
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:757:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn fwprintf_s(_File: [*c]FILE, _Format: [*c]const wchar_t, ...) c_int;
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:766:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn wprintf_s(_Format: [*c]const wchar_t, ...) c_int;
pub fn _vswprintf_s_l(arg__DstBuf: [*c]wchar_t, arg__DstSize: usize, arg__Format: [*c]const wchar_t, arg__Locale: _locale_t, arg__ArgList: va_list) callconv(.c) c_int {
    var _DstBuf = arg__DstBuf;
    _ = &_DstBuf;
    var _DstSize = arg__DstSize;
    _ = &_DstSize;
    var _Format = arg__Format;
    _ = &_Format;
    var _Locale = arg__Locale;
    _ = &_Locale;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return __stdio_common_vswprintf_s(__local_stdio_printf_options().*, _DstBuf, _DstSize, _Format, _Locale, _ArgList);
}
pub fn vswprintf_s(arg__DstBuf: [*c]wchar_t, arg__DstSize: usize, arg__Format: [*c]const wchar_t, arg__ArgList: va_list) callconv(.c) c_int {
    var _DstBuf = arg__DstBuf;
    _ = &_DstBuf;
    var _DstSize = arg__DstSize;
    _ = &_DstSize;
    var _Format = arg__Format;
    _ = &_Format;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return _vswprintf_s_l(_DstBuf, _DstSize, _Format, null, _ArgList);
}
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:784:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _swprintf_s_l(_DstBuf: [*c]wchar_t, _DstSize: usize, _Format: [*c]const wchar_t, _Locale: _locale_t, ...) c_int;
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:793:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn swprintf_s(_DstBuf: [*c]wchar_t, _DstSize: usize, _Format: [*c]const wchar_t, ...) c_int;
pub fn _vsnwprintf_s_l(arg__DstBuf: [*c]wchar_t, arg__DstSize: usize, arg__MaxCount: usize, arg__Format: [*c]const wchar_t, arg__Locale: _locale_t, arg__ArgList: va_list) callconv(.c) c_int {
    var _DstBuf = arg__DstBuf;
    _ = &_DstBuf;
    var _DstSize = arg__DstSize;
    _ = &_DstSize;
    var _MaxCount = arg__MaxCount;
    _ = &_MaxCount;
    var _Format = arg__Format;
    _ = &_Format;
    var _Locale = arg__Locale;
    _ = &_Locale;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return __stdio_common_vsnwprintf_s(__local_stdio_printf_options().*, _DstBuf, _DstSize, _MaxCount, _Format, _Locale, _ArgList);
}
pub fn _vsnwprintf_s(arg__DstBuf: [*c]wchar_t, arg__DstSize: usize, arg__MaxCount: usize, arg__Format: [*c]const wchar_t, arg__ArgList: va_list) callconv(.c) c_int {
    var _DstBuf = arg__DstBuf;
    _ = &_DstBuf;
    var _DstSize = arg__DstSize;
    _ = &_DstSize;
    var _MaxCount = arg__MaxCount;
    _ = &_MaxCount;
    var _Format = arg__Format;
    _ = &_Format;
    var _ArgList = arg__ArgList;
    _ = &_ArgList;
    return _vsnwprintf_s_l(_DstBuf, _DstSize, _MaxCount, _Format, null, _ArgList);
}
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:811:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _snwprintf_s_l(_DstBuf: [*c]wchar_t, _DstSize: usize, _MaxCount: usize, _Format: [*c]const wchar_t, _Locale: _locale_t, ...) c_int;
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:820:27: warning: TODO unable to translate variadic function, demoted to extern
pub extern fn _snwprintf_s(_DstBuf: [*c]wchar_t, _DstSize: usize, _MaxCount: usize, _Format: [*c]const wchar_t, ...) c_int;
pub extern fn _wfopen_s(_File: [*c][*c]FILE, _Filename: [*c]const wchar_t, _Mode: [*c]const wchar_t) errno_t;
pub extern fn _wfreopen_s(_File: [*c][*c]FILE, _Filename: [*c]const wchar_t, _Mode: [*c]const wchar_t, _OldFile: [*c]FILE) errno_t;
pub extern fn _wtmpnam_s(_DstBuf: [*c]wchar_t, _SizeInWords: usize) errno_t;
pub extern fn _fread_nolock_s(_DstBuf: ?*anyopaque, _DstSize: usize, _ElementSize: usize, _Count: usize, _File: [*c]FILE) usize;
pub const max_align_t = extern struct {
    __aro_max_align_ll: c_longlong = 0,
    __aro_max_align_ld: c_longdouble = 0,
};
pub const int_least8_t = i8;
pub const uint_least8_t = u8;
pub const int_least16_t = c_short;
pub const uint_least16_t = c_ushort;
pub const int_least32_t = c_int;
pub const uint_least32_t = c_uint;
pub const int_least64_t = c_longlong;
pub const uint_least64_t = c_ulonglong;
pub const int_fast8_t = i8;
pub const uint_fast8_t = u8;
pub const int_fast16_t = c_short;
pub const uint_fast16_t = c_ushort;
pub const int_fast32_t = c_int;
pub const uint_fast32_t = c_uint;
pub const int_fast64_t = c_longlong;
pub const uint_fast64_t = c_ulonglong;
pub const intmax_t = c_longlong;
pub const uintmax_t = c_ulonglong;
pub extern fn _memccpy(_Dst: ?*anyopaque, _Src: ?*const anyopaque, _Val: c_int, _MaxCount: usize) ?*anyopaque;
pub extern fn memccpy(_Dst: ?*anyopaque, _Src: ?*const anyopaque, _Val: c_int, _Size: usize) ?*anyopaque;
pub extern fn memchr(_Buf: ?*const anyopaque, _Val: c_int, _MaxCount: usize) ?*anyopaque;
pub extern fn _memicmp(_Buf1: ?*const anyopaque, _Buf2: ?*const anyopaque, _Size: usize) c_int;
pub extern fn _memicmp_l(_Buf1: ?*const anyopaque, _Buf2: ?*const anyopaque, _Size: usize, _Locale: _locale_t) c_int;
pub extern fn memcmp(_Buf1: ?*const anyopaque, _Buf2: ?*const anyopaque, _Size: usize) c_int;
pub extern fn memcpy(noalias _Dst: ?*anyopaque, noalias _Src: ?*const anyopaque, _Size: usize) ?*anyopaque;
pub extern fn memcpy_s(_dest: ?*anyopaque, _numberOfElements: usize, _src: ?*const anyopaque, _count: usize) errno_t;
pub extern fn mempcpy(_Dst: ?*anyopaque, _Src: ?*const anyopaque, _Size: usize) ?*anyopaque;
pub extern fn memset(_Dst: ?*anyopaque, _Val: c_int, _Size: usize) ?*anyopaque;
pub extern fn memset_explicit(_Dst: ?*anyopaque, _Val: c_int, _Size: usize) ?*anyopaque;
pub extern fn memicmp(_Buf1: ?*const anyopaque, _Buf2: ?*const anyopaque, _Size: usize) c_int;
pub extern fn _strset(_Str: [*c]u8, _Val: c_int) [*c]u8;
pub extern fn _strset_l(_Str: [*c]u8, _Val: c_int, _Locale: _locale_t) [*c]u8;
pub extern fn strcpy(noalias _Dest: [*c]u8, noalias _Source: [*c]const u8) [*c]u8;
pub extern fn strcat(noalias _Dest: [*c]u8, noalias _Source: [*c]const u8) [*c]u8;
pub extern fn strcmp(_Str1: [*c]const u8, _Str2: [*c]const u8) c_int;
pub extern fn strlen(_Str: [*c]const u8) usize;
pub extern fn strnlen(_Str: [*c]const u8, _MaxCount: usize) usize;
pub extern fn memmove(_Dst: ?*anyopaque, _Src: ?*const anyopaque, _Size: usize) ?*anyopaque;
pub extern fn _strdup(_Src: [*c]const u8) [*c]u8;
pub extern fn strdup(_Src: [*c]const u8) [*c]u8;
pub extern fn strndup(_Src: [*c]const u8, _MaxCount: usize) [*c]u8;
pub extern fn strchr(_Str: [*c]const u8, _Val: c_int) [*c]u8;
pub extern fn _stricmp(_Str1: [*c]const u8, _Str2: [*c]const u8) c_int;
pub extern fn _strcmpi(_Str1: [*c]const u8, _Str2: [*c]const u8) c_int;
pub extern fn _stricmp_l(_Str1: [*c]const u8, _Str2: [*c]const u8, _Locale: _locale_t) c_int;
pub extern fn strcoll(_Str1: [*c]const u8, _Str2: [*c]const u8) c_int;
pub extern fn _strcoll_l(_Str1: [*c]const u8, _Str2: [*c]const u8, _Locale: _locale_t) c_int;
pub extern fn _stricoll(_Str1: [*c]const u8, _Str2: [*c]const u8) c_int;
pub extern fn _stricoll_l(_Str1: [*c]const u8, _Str2: [*c]const u8, _Locale: _locale_t) c_int;
pub extern fn _strncoll(_Str1: [*c]const u8, _Str2: [*c]const u8, _MaxCount: usize) c_int;
pub extern fn _strncoll_l(_Str1: [*c]const u8, _Str2: [*c]const u8, _MaxCount: usize, _Locale: _locale_t) c_int;
pub extern fn _strnicoll(_Str1: [*c]const u8, _Str2: [*c]const u8, _MaxCount: usize) c_int;
pub extern fn _strnicoll_l(_Str1: [*c]const u8, _Str2: [*c]const u8, _MaxCount: usize, _Locale: _locale_t) c_int;
pub extern fn strcspn(_Str: [*c]const u8, _Control: [*c]const u8) usize;
pub extern fn _strerror(_ErrMsg: [*c]const u8) [*c]u8;
pub extern fn strerror(c_int) [*c]u8;
pub extern fn _strlwr(_String: [*c]u8) [*c]u8;
pub extern fn strlwr_l(_String: [*c]u8, _Locale: _locale_t) [*c]u8;
pub extern fn strncat(noalias _Dest: [*c]u8, noalias _Source: [*c]const u8, _Count: usize) [*c]u8;
pub extern fn strncmp(_Str1: [*c]const u8, _Str2: [*c]const u8, _MaxCount: usize) c_int;
pub extern fn _strnicmp(_Str1: [*c]const u8, _Str2: [*c]const u8, _MaxCount: usize) c_int;
pub extern fn _strnicmp_l(_Str1: [*c]const u8, _Str2: [*c]const u8, _MaxCount: usize, _Locale: _locale_t) c_int;
pub extern fn strncpy(noalias _Dest: [*c]u8, noalias _Source: [*c]const u8, _Count: usize) [*c]u8;
pub extern fn _strnset(_Str: [*c]u8, _Val: c_int, _MaxCount: usize) [*c]u8;
pub extern fn _strnset_l(str: [*c]u8, c: c_int, count: usize, _Locale: _locale_t) [*c]u8;
pub extern fn strpbrk(_Str: [*c]const u8, _Control: [*c]const u8) [*c]u8;
pub extern fn strrchr(_Str: [*c]const u8, _Ch: c_int) [*c]u8;
pub extern fn _strrev(_Str: [*c]u8) [*c]u8;
pub extern fn strspn(_Str: [*c]const u8, _Control: [*c]const u8) usize;
pub extern fn strstr(_Str: [*c]const u8, _SubStr: [*c]const u8) [*c]u8;
pub extern fn strtok(noalias _Str: [*c]u8, noalias _Delim: [*c]const u8) [*c]u8;
pub extern fn strtok_r(noalias _Str: [*c]u8, noalias _Delim: [*c]const u8, noalias __last: [*c][*c]u8) [*c]u8;
pub extern fn _strupr(_String: [*c]u8) [*c]u8;
pub extern fn _strupr_l(_String: [*c]u8, _Locale: _locale_t) [*c]u8;
pub extern fn strxfrm(noalias _Dst: [*c]u8, noalias _Src: [*c]const u8, _MaxCount: usize) usize;
pub extern fn _strxfrm_l(noalias _Dst: [*c]u8, noalias _Src: [*c]const u8, _MaxCount: usize, _Locale: _locale_t) usize;
pub extern fn strcmpi(_Str1: [*c]const u8, _Str2: [*c]const u8) c_int;
pub extern fn stricmp(_Str1: [*c]const u8, _Str2: [*c]const u8) c_int;
pub extern fn strlwr(_Str: [*c]u8) [*c]u8;
pub extern fn strnicmp(_Str1: [*c]const u8, _Str: [*c]const u8, _MaxCount: usize) c_int;
pub extern fn strncasecmp([*c]const u8, [*c]const u8, usize) c_int;
pub extern fn strcasecmp([*c]const u8, [*c]const u8) c_int;
pub extern fn strnset(_Str: [*c]u8, _Val: c_int, _MaxCount: usize) [*c]u8;
pub extern fn strrev(_Str: [*c]u8) [*c]u8;
pub extern fn strset(_Str: [*c]u8, _Val: c_int) [*c]u8;
pub extern fn strupr(_Str: [*c]u8) [*c]u8;
pub extern fn _wcsdup(_Str: [*c]const wchar_t) [*c]wchar_t;
pub extern fn wcscat(noalias _Dest: [*c]wchar_t, noalias _Source: [*c]const wchar_t) [*c]wchar_t;
pub extern fn wcschr(_Str: [*c]const wchar_t, _Ch: wchar_t) [*c]wchar_t;
pub extern fn wcscmp(_Str1: [*c]const wchar_t, _Str2: [*c]const wchar_t) c_int;
pub extern fn wcscpy(noalias _Dest: [*c]wchar_t, noalias _Source: [*c]const wchar_t) [*c]wchar_t;
pub extern fn wcscspn(_Str: [*c]const wchar_t, _Control: [*c]const wchar_t) usize;
pub extern fn wcslen(_Str: [*c]const wchar_t) usize;
pub extern fn wcsnlen(_Src: [*c]const wchar_t, _MaxCount: usize) usize;
pub extern fn wcsncat(noalias _Dest: [*c]wchar_t, noalias _Source: [*c]const wchar_t, _Count: usize) [*c]wchar_t;
pub extern fn wcsncmp(_Str1: [*c]const wchar_t, _Str2: [*c]const wchar_t, _MaxCount: usize) c_int;
pub extern fn wcsncpy(noalias _Dest: [*c]wchar_t, noalias _Source: [*c]const wchar_t, _Count: usize) [*c]wchar_t;
pub extern fn _wcsncpy_l(noalias _Dest: [*c]wchar_t, noalias _Source: [*c]const wchar_t, _Count: usize, _Locale: _locale_t) [*c]wchar_t;
pub extern fn wcspbrk(_Str: [*c]const wchar_t, _Control: [*c]const wchar_t) [*c]wchar_t;
pub extern fn wcsrchr(_Str: [*c]const wchar_t, _Ch: wchar_t) [*c]wchar_t;
pub extern fn wcsspn(_Str: [*c]const wchar_t, _Control: [*c]const wchar_t) usize;
pub extern fn wcsstr(_Str: [*c]const wchar_t, _SubStr: [*c]const wchar_t) [*c]wchar_t;
pub extern fn wcstok(noalias _Str: [*c]wchar_t, noalias _Delim: [*c]const wchar_t, noalias _Ptr: [*c][*c]wchar_t) [*c]wchar_t;
pub extern fn _wcstok(noalias _Str: [*c]wchar_t, noalias _Delim: [*c]const wchar_t) [*c]wchar_t;
pub extern fn _wcserror(_ErrNum: c_int) [*c]wchar_t;
pub extern fn __wcserror(_Str: [*c]const wchar_t) [*c]wchar_t;
pub extern fn _wcsicmp(_Str1: [*c]const wchar_t, _Str2: [*c]const wchar_t) c_int;
pub extern fn _wcsicmp_l(_Str1: [*c]const wchar_t, _Str2: [*c]const wchar_t, _Locale: _locale_t) c_int;
pub extern fn _wcsnicmp(_Str1: [*c]const wchar_t, _Str2: [*c]const wchar_t, _MaxCount: usize) c_int;
pub extern fn _wcsnicmp_l(_Str1: [*c]const wchar_t, _Str2: [*c]const wchar_t, _MaxCount: usize, _Locale: _locale_t) c_int;
pub extern fn _wcsnset(_Str: [*c]wchar_t, _Val: wchar_t, _MaxCount: usize) [*c]wchar_t;
pub extern fn _wcsrev(_Str: [*c]wchar_t) [*c]wchar_t;
pub extern fn _wcsset(_Str: [*c]wchar_t, _Val: wchar_t) [*c]wchar_t;
pub extern fn _wcslwr(_String: [*c]wchar_t) [*c]wchar_t;
pub extern fn _wcslwr_l(_String: [*c]wchar_t, _Locale: _locale_t) [*c]wchar_t;
pub extern fn _wcsupr(_String: [*c]wchar_t) [*c]wchar_t;
pub extern fn _wcsupr_l(_String: [*c]wchar_t, _Locale: _locale_t) [*c]wchar_t;
pub extern fn wcsxfrm(noalias _Dst: [*c]wchar_t, noalias _Src: [*c]const wchar_t, _MaxCount: usize) usize;
pub extern fn _wcsxfrm_l(noalias _Dst: [*c]wchar_t, noalias _Src: [*c]const wchar_t, _MaxCount: usize, _Locale: _locale_t) usize;
pub extern fn wcscoll(_Str1: [*c]const wchar_t, _Str2: [*c]const wchar_t) c_int;
pub extern fn _wcscoll_l(_Str1: [*c]const wchar_t, _Str2: [*c]const wchar_t, _Locale: _locale_t) c_int;
pub extern fn _wcsicoll(_Str1: [*c]const wchar_t, _Str2: [*c]const wchar_t) c_int;
pub extern fn _wcsicoll_l(_Str1: [*c]const wchar_t, _Str2: [*c]const wchar_t, _Locale: _locale_t) c_int;
pub extern fn _wcsncoll(_Str1: [*c]const wchar_t, _Str2: [*c]const wchar_t, _MaxCount: usize) c_int;
pub extern fn _wcsncoll_l(_Str1: [*c]const wchar_t, _Str2: [*c]const wchar_t, _MaxCount: usize, _Locale: _locale_t) c_int;
pub extern fn _wcsnicoll(_Str1: [*c]const wchar_t, _Str2: [*c]const wchar_t, _MaxCount: usize) c_int;
pub extern fn _wcsnicoll_l(_Str1: [*c]const wchar_t, _Str2: [*c]const wchar_t, _MaxCount: usize, _Locale: _locale_t) c_int;
pub extern fn wcsdup(_Str: [*c]const wchar_t) [*c]wchar_t;
pub extern fn wcsicmp(_Str1: [*c]const wchar_t, _Str2: [*c]const wchar_t) c_int;
pub extern fn wcsnicmp(_Str1: [*c]const wchar_t, _Str2: [*c]const wchar_t, _MaxCount: usize) c_int;
pub extern fn wcsnset(_Str: [*c]wchar_t, _Val: wchar_t, _MaxCount: usize) [*c]wchar_t;
pub extern fn wcsrev(_Str: [*c]wchar_t) [*c]wchar_t;
pub extern fn wcsset(_Str: [*c]wchar_t, _Val: wchar_t) [*c]wchar_t;
pub extern fn wcslwr(_Str: [*c]wchar_t) [*c]wchar_t;
pub extern fn wcsupr(_Str: [*c]wchar_t) [*c]wchar_t;
pub extern fn wcsicoll(_Str1: [*c]const wchar_t, _Str2: [*c]const wchar_t) c_int;
pub extern fn _strset_s(_Dst: [*c]u8, _DstSize: usize, _Value: c_int) errno_t;
pub extern fn _strerror_s(_Buf: [*c]u8, _SizeInBytes: usize, _ErrMsg: [*c]const u8) errno_t;
pub extern fn strerror_s(_Buf: [*c]u8, _SizeInBytes: usize, _ErrNum: c_int) errno_t;
pub extern fn _strlwr_s(_Str: [*c]u8, _Size: usize) errno_t;
pub extern fn _strlwr_s_l(_Str: [*c]u8, _Size: usize, _Locale: _locale_t) errno_t;
pub extern fn _strnset_s(_Str: [*c]u8, _Size: usize, _Val: c_int, _MaxCount: usize) errno_t;
pub extern fn _strupr_s(_Str: [*c]u8, _Size: usize) errno_t;
pub extern fn _strupr_s_l(_Str: [*c]u8, _Size: usize, _Locale: _locale_t) errno_t;
pub extern fn strncat_s(_Dst: [*c]u8, _DstSizeInChars: usize, _Src: [*c]const u8, _MaxCount: usize) errno_t;
pub extern fn _strncat_s_l(_Dst: [*c]u8, _DstSizeInChars: usize, _Src: [*c]const u8, _MaxCount: usize, _Locale: _locale_t) errno_t;
pub extern fn strcpy_s(_Dst: [*c]u8, _SizeInBytes: rsize_t, _Src: [*c]const u8) errno_t;
pub extern fn strncpy_s(_Dst: [*c]u8, _DstSizeInChars: usize, _Src: [*c]const u8, _MaxCount: usize) errno_t;
pub extern fn _strncpy_s_l(_Dst: [*c]u8, _DstSizeInChars: usize, _Src: [*c]const u8, _MaxCount: usize, _Locale: _locale_t) errno_t;
pub extern fn strtok_s(_Str: [*c]u8, _Delim: [*c]const u8, _Context: [*c][*c]u8) [*c]u8;
pub extern fn _strtok_s_l(_Str: [*c]u8, _Delim: [*c]const u8, _Context: [*c][*c]u8, _Locale: _locale_t) [*c]u8;
pub extern fn strcat_s(_Dst: [*c]u8, _SizeInBytes: rsize_t, _Src: [*c]const u8) errno_t;
// tools\zig\lib\libc\include\any-windows-any\sec_api\string_s.h:56:32: warning: cdecl calling convention ignored on inline function
pub inline fn strnlen_s(arg__src: [*c]const u8, arg__count: usize) usize {
    var _src = arg__src;
    _ = &_src;
    var _count = arg__count;
    _ = &_count;
    return if (_src != null) strnlen(_src, _count) else @as(usize, 0);
}
pub extern fn memmove_s(_dest: ?*anyopaque, _numberOfElements: usize, _src: ?*const anyopaque, _count: usize) errno_t;
pub extern fn wcstok_s(_Str: [*c]wchar_t, _Delim: [*c]const wchar_t, _Context: [*c][*c]wchar_t) [*c]wchar_t;
pub extern fn _wcserror_s(_Buf: [*c]wchar_t, _SizeInWords: usize, _ErrNum: c_int) errno_t;
pub extern fn __wcserror_s(_Buffer: [*c]wchar_t, _SizeInWords: usize, _ErrMsg: [*c]const wchar_t) errno_t;
pub extern fn _wcsnset_s(_Dst: [*c]wchar_t, _DstSizeInWords: usize, _Val: wchar_t, _MaxCount: usize) errno_t;
pub extern fn _wcsset_s(_Str: [*c]wchar_t, _SizeInWords: usize, _Val: wchar_t) errno_t;
pub extern fn _wcslwr_s(_Str: [*c]wchar_t, _SizeInWords: usize) errno_t;
pub extern fn _wcslwr_s_l(_Str: [*c]wchar_t, _SizeInWords: usize, _Locale: _locale_t) errno_t;
pub extern fn _wcsupr_s(_Str: [*c]wchar_t, _Size: usize) errno_t;
pub extern fn _wcsupr_s_l(_Str: [*c]wchar_t, _Size: usize, _Locale: _locale_t) errno_t;
pub extern fn wcscpy_s(_Dst: [*c]wchar_t, _SizeInWords: rsize_t, _Src: [*c]const wchar_t) errno_t;
pub extern fn wcscat_s(_Dst: [*c]wchar_t, _SizeInWords: rsize_t, _Src: [*c]const wchar_t) errno_t;
pub extern fn wcsncat_s(_Dst: [*c]wchar_t, _DstSizeInChars: usize, _Src: [*c]const wchar_t, _MaxCount: usize) errno_t;
pub extern fn _wcsncat_s_l(_Dst: [*c]wchar_t, _DstSizeInChars: usize, _Src: [*c]const wchar_t, _MaxCount: usize, _Locale: _locale_t) errno_t;
pub extern fn wcsncpy_s(_Dst: [*c]wchar_t, _DstSizeInChars: usize, _Src: [*c]const wchar_t, _MaxCount: usize) errno_t;
pub extern fn _wcsncpy_s_l(_Dst: [*c]wchar_t, _DstSizeInChars: usize, _Src: [*c]const wchar_t, _MaxCount: usize, _Locale: _locale_t) errno_t;
pub extern fn _wcstok_s_l(_Str: [*c]wchar_t, _Delim: [*c]const wchar_t, _Context: [*c][*c]wchar_t, _Locale: _locale_t) [*c]wchar_t;
pub extern fn _wcsset_s_l(_Str: [*c]wchar_t, _SizeInChars: usize, _Val: wchar_t, _Locale: _locale_t) errno_t;
pub extern fn _wcsnset_s_l(_Str: [*c]wchar_t, _SizeInChars: usize, _Val: wchar_t, _Count: usize, _Locale: _locale_t) errno_t;
// tools\zig\lib\libc\include\any-windows-any\sec_api\string_s.h:97:32: warning: cdecl calling convention ignored on inline function
pub inline fn wcsnlen_s(arg__src: [*c]const wchar_t, arg__count: usize) usize {
    var _src = arg__src;
    _ = &_src;
    var _count = arg__count;
    _ = &_count;
    return if (_src != null) wcsnlen(_src, _count) else @as(usize, 0);
}
pub const struct__exception = extern struct {
    type: c_int = 0,
    name: [*c]const u8 = null,
    arg1: f64 = 0,
    arg2: f64 = 0,
    retval: f64 = 0,
    pub const _matherr = __root._matherr;
};
const struct_unnamed_1 = extern struct {
    low: c_uint = 0,
    high: c_uint = 0,
};
pub const union___mingw_dbl_type_t = extern union {
    x: f64,
    val: c_ulonglong,
    lh: struct_unnamed_1,
};
pub const __mingw_dbl_type_t = union___mingw_dbl_type_t;
pub const union___mingw_flt_type_t = extern union {
    x: f32,
    val: c_uint,
};
pub const __mingw_flt_type_t = union___mingw_flt_type_t;
// tools\zig\lib\libc\include\any-windows-any\math.h:135:11: warning: struct demoted to opaque type - has bitfield
const struct_unnamed_2 = opaque {};
// tools\zig\lib\libc\include\any-windows-any\math.h:138:7: warning: union demoted to opaque type - has opaque field
pub const union___mingw_ldbl_type_t = opaque {};
pub const __mingw_ldbl_type_t = union___mingw_ldbl_type_t;
pub extern var __imp__HUGE: [*c]f64;
pub extern fn __mingw_raise_matherr(typ: c_int, name: [*c]const u8, a1: f64, a2: f64, rslt: f64) void;
pub extern fn __mingw_setusermatherr(?*const fn ([*c]struct__exception) callconv(.c) c_int) void;
pub extern fn __setusermatherr(?*const fn ([*c]struct__exception) callconv(.c) c_int) void;
pub extern fn sin(_X: f64) f64;
pub extern fn cos(_X: f64) f64;
pub extern fn tan(_X: f64) f64;
pub extern fn sinh(_X: f64) f64;
pub extern fn cosh(_X: f64) f64;
pub extern fn tanh(_X: f64) f64;
pub extern fn asin(_X: f64) f64;
pub extern fn acos(_X: f64) f64;
pub extern fn atan(_X: f64) f64;
pub extern fn atan2(_Y: f64, _X: f64) f64;
pub extern fn exp(_X: f64) f64;
pub extern fn log(_X: f64) f64;
pub extern fn log10(_X: f64) f64;
pub extern fn pow(_X: f64, _Y: f64) f64;
pub extern fn sqrt(_X: f64) f64;
pub extern fn ceil(_X: f64) f64;
pub extern fn floor(_X: f64) f64;
pub extern fn fabsf(x: f32) f32;
pub extern fn fabsl(c_longdouble) c_longdouble;
pub extern fn fabs(_X: f64) f64;
pub extern fn ldexp(_X: f64, _Y: c_int) f64;
pub extern fn frexp(_X: f64, _Y: [*c]c_int) f64;
pub extern fn modf(_X: f64, _Y: [*c]f64) f64;
pub extern fn fmod(_X: f64, _Y: f64) f64;
pub extern fn sincos(__x: f64, p_sin: [*c]f64, p_cos: [*c]f64) void;
pub extern fn sincosl(__x: c_longdouble, p_sin: [*c]c_longdouble, p_cos: [*c]c_longdouble) void;
pub extern fn sincosf(__x: f32, p_sin: [*c]f32, p_cos: [*c]f32) void;
pub extern fn abs(_X: c_int) c_int;
pub extern fn labs(_X: c_long) c_long;
pub extern fn atof(_String: [*c]const u8) f64;
pub extern fn _atof_l(_String: [*c]const u8, _Locale: _locale_t) f64;
pub const struct__complex = extern struct {
    x: f64 = 0,
    y: f64 = 0,
    pub const _cabs = __root._cabs;
    pub const cabs = __root._cabs;
};
pub extern fn _cabs(_ComplexA: struct__complex) f64;
pub extern fn _hypot(_X: f64, _Y: f64) f64;
pub extern fn _j0(_X: f64) f64;
pub extern fn _j1(_X: f64) f64;
pub extern fn _jn(_X: c_int, _Y: f64) f64;
pub extern fn _y0(_X: f64) f64;
pub extern fn _y1(_X: f64) f64;
pub extern fn _yn(_X: c_int, _Y: f64) f64;
pub extern fn _matherr([*c]struct__exception) c_int;
pub extern fn _chgsign(_X: f64) f64;
pub extern fn _copysign(_Number: f64, _Sign: f64) f64;
pub extern fn _logb(f64) f64;
pub extern fn _nextafter(f64, f64) f64;
pub extern fn _scalb(f64, c_long) f64;
pub extern fn _finite(f64) c_int;
pub extern fn _fpclass(f64) c_int;
pub extern fn _isnan(f64) c_int;
pub extern fn j0(f64) f64;
pub extern fn j1(f64) f64;
pub extern fn jn(c_int, f64) f64;
pub extern fn y0(f64) f64;
pub extern fn y1(f64) f64;
pub extern fn yn(c_int, f64) f64;
pub extern fn chgsign(f64) f64;
pub extern fn finite(f64) c_int;
pub extern fn fpclass(f64) c_int;
pub const float_t = f32;
pub const double_t = f64;
pub extern fn __fpclassifyl(c_longdouble) c_int;
pub extern fn __fpclassifyf(f32) c_int;
pub extern fn __fpclassify(f64) c_int;
pub extern fn __isnan(f64) c_int;
pub extern fn __isnanf(f32) c_int;
pub extern fn __isnanl(c_longdouble) c_int;
pub extern fn __signbit(f64) c_int;
pub extern fn __signbitf(f32) c_int;
pub extern fn __signbitl(c_longdouble) c_int;
pub extern fn sinf(_X: f32) f32;
pub extern fn sinl(c_longdouble) c_longdouble;
pub extern fn cosf(_X: f32) f32;
pub extern fn cosl(c_longdouble) c_longdouble;
pub extern fn tanf(_X: f32) f32;
pub extern fn tanl(c_longdouble) c_longdouble;
pub extern fn asinf(_X: f32) f32;
pub extern fn asinl(c_longdouble) c_longdouble;
pub extern fn acosf(f32) f32;
pub extern fn acosl(c_longdouble) c_longdouble;
pub extern fn atanf(f32) f32;
pub extern fn atanl(c_longdouble) c_longdouble;
pub extern fn atan2f(f32, f32) f32;
pub extern fn atan2l(c_longdouble, c_longdouble) c_longdouble;
pub extern fn sinhf(_X: f32) f32;
pub extern fn sinhl(c_longdouble) c_longdouble;
pub extern fn coshf(_X: f32) f32;
pub extern fn coshl(c_longdouble) c_longdouble;
pub extern fn tanhf(_X: f32) f32;
pub extern fn tanhl(c_longdouble) c_longdouble;
pub extern fn acosh(f64) f64;
pub extern fn acoshf(f32) f32;
pub extern fn acoshl(c_longdouble) c_longdouble;
pub extern fn asinh(f64) f64;
pub extern fn asinhf(f32) f32;
pub extern fn asinhl(c_longdouble) c_longdouble;
pub extern fn atanh(f64) f64;
pub extern fn atanhf(f32) f32;
pub extern fn atanhl(c_longdouble) c_longdouble;
pub extern fn expf(_X: f32) f32;
pub extern fn expl(c_longdouble) c_longdouble;
pub extern fn exp2(f64) f64;
pub extern fn exp2f(f32) f32;
pub extern fn exp2l(c_longdouble) c_longdouble;
pub extern fn expm1(f64) f64;
pub extern fn expm1f(f32) f32;
pub extern fn expm1l(c_longdouble) c_longdouble;
pub extern fn frexpf(_X: f32, _Y: [*c]c_int) f32;
pub extern fn frexpl(c_longdouble, [*c]c_int) c_longdouble;
pub extern fn ilogb(f64) c_int;
pub extern fn ilogbf(f32) c_int;
pub extern fn ilogbl(c_longdouble) c_int;
pub extern fn ldexpf(_X: f32, _Y: c_int) f32;
pub extern fn ldexpl(c_longdouble, c_int) c_longdouble;
pub extern fn logf(f32) f32;
pub extern fn logl(c_longdouble) c_longdouble;
pub extern fn log10f(f32) f32;
pub extern fn log10l(c_longdouble) c_longdouble;
pub extern fn log1p(f64) f64;
pub extern fn log1pf(f32) f32;
pub extern fn log1pl(c_longdouble) c_longdouble;
pub extern fn log2(f64) f64;
pub extern fn log2f(f32) f32;
pub extern fn log2l(c_longdouble) c_longdouble;
pub extern fn logb(f64) f64;
pub extern fn logbf(f32) f32;
pub extern fn logbl(c_longdouble) c_longdouble;
pub extern fn modff(f32, [*c]f32) f32;
pub extern fn modfl(c_longdouble, [*c]c_longdouble) c_longdouble;
pub extern fn scalbn(f64, c_int) f64;
pub extern fn scalbnf(f32, c_int) f32;
pub extern fn scalbnl(c_longdouble, c_int) c_longdouble;
pub extern fn scalbln(f64, c_long) f64;
pub extern fn scalblnf(f32, c_long) f32;
pub extern fn scalblnl(c_longdouble, c_long) c_longdouble;
pub extern fn cbrt(f64) f64;
pub extern fn cbrtf(f32) f32;
pub extern fn cbrtl(c_longdouble) c_longdouble;
pub extern fn hypot(f64, f64) f64;
pub extern fn hypotf(x: f32, y: f32) f32;
pub extern fn hypotl(c_longdouble, c_longdouble) c_longdouble;
pub extern fn powf(_X: f32, _Y: f32) f32;
pub extern fn powl(c_longdouble, c_longdouble) c_longdouble;
pub extern fn sqrtf(f32) f32;
pub extern fn sqrtl(c_longdouble) c_longdouble;
pub extern fn erf(f64) f64;
pub extern fn erff(f32) f32;
pub extern fn erfl(c_longdouble) c_longdouble;
pub extern fn erfc(f64) f64;
pub extern fn erfcf(f32) f32;
pub extern fn erfcl(c_longdouble) c_longdouble;
pub extern fn lgamma(f64) f64;
pub extern fn lgammaf(f32) f32;
pub extern fn lgammal(c_longdouble) c_longdouble;
pub extern var signgam: c_int;
pub extern fn tgamma(f64) f64;
pub extern fn tgammaf(f32) f32;
pub extern fn tgammal(c_longdouble) c_longdouble;
pub extern fn ceilf(f32) f32;
pub extern fn ceill(c_longdouble) c_longdouble;
pub extern fn floorf(f32) f32;
pub extern fn floorl(c_longdouble) c_longdouble;
pub extern fn nearbyint(f64) f64;
pub extern fn nearbyintf(f32) f32;
pub extern fn nearbyintl(c_longdouble) c_longdouble;
pub extern fn rint(f64) f64;
pub extern fn rintf(f32) f32;
pub extern fn rintl(c_longdouble) c_longdouble;
pub extern fn lrint(f64) c_long;
pub extern fn lrintf(f32) c_long;
pub extern fn lrintl(c_longdouble) c_long;
pub extern fn llrint(f64) c_longlong;
pub extern fn llrintf(f32) c_longlong;
pub extern fn llrintl(c_longdouble) c_longlong;
pub extern fn round(f64) f64;
pub extern fn roundf(f32) f32;
pub extern fn roundl(c_longdouble) c_longdouble;
pub extern fn lround(f64) c_long;
pub extern fn lroundf(f32) c_long;
pub extern fn lroundl(c_longdouble) c_long;
pub extern fn llround(f64) c_longlong;
pub extern fn llroundf(f32) c_longlong;
pub extern fn llroundl(c_longdouble) c_longlong;
pub extern fn trunc(f64) f64;
pub extern fn truncf(f32) f32;
pub extern fn truncl(c_longdouble) c_longdouble;
pub extern fn fmodf(f32, f32) f32;
pub extern fn fmodl(c_longdouble, c_longdouble) c_longdouble;
pub extern fn remainder(f64, f64) f64;
pub extern fn remainderf(f32, f32) f32;
pub extern fn remainderl(c_longdouble, c_longdouble) c_longdouble;
pub extern fn remquo(f64, f64, [*c]c_int) f64;
pub extern fn remquof(f32, f32, [*c]c_int) f32;
pub extern fn remquol(c_longdouble, c_longdouble, [*c]c_int) c_longdouble;
pub extern fn copysign(f64, f64) f64;
pub extern fn copysignf(f32, f32) f32;
pub extern fn copysignl(c_longdouble, c_longdouble) c_longdouble;
pub extern fn nan(tagp: [*c]const u8) f64;
pub extern fn nanf(tagp: [*c]const u8) f32;
pub extern fn nanl(tagp: [*c]const u8) c_longdouble;
pub extern fn nextafter(f64, f64) f64;
pub extern fn nextafterf(f32, f32) f32;
pub extern fn nextafterl(c_longdouble, c_longdouble) c_longdouble;
pub extern fn nexttoward(f64, c_longdouble) f64;
pub extern fn nexttowardf(f32, c_longdouble) f32;
pub extern fn nexttowardl(c_longdouble, c_longdouble) c_longdouble;
pub extern fn fdim(x: f64, y: f64) f64;
pub extern fn fdimf(x: f32, y: f32) f32;
pub extern fn fdiml(x: c_longdouble, y: c_longdouble) c_longdouble;
pub extern fn fmax(f64, f64) f64;
pub extern fn fmaxf(f32, f32) f32;
pub extern fn fmaxl(c_longdouble, c_longdouble) c_longdouble;
pub extern fn fmin(f64, f64) f64;
pub extern fn fminf(f32, f32) f32;
pub extern fn fminl(c_longdouble, c_longdouble) c_longdouble;
pub extern fn fma(f64, f64, f64) f64;
pub extern fn fmaf(f32, f32, f32) f32;
pub extern fn fmal(c_longdouble, c_longdouble, c_longdouble) c_longdouble;
pub extern fn _copysignf(_Number: f32, _Sign: f32) f32;
pub extern fn _chgsignf(_X: f32) f32;
pub extern fn _logbf(_X: f32) f32;
pub extern fn _nextafterf(_X: f32, _Y: f32) f32;
pub extern fn _finitef(_X: f32) c_int;
pub extern fn _isnanf(_X: f32) c_int;
pub extern fn _fpclassf(_X: f32) c_int;
pub extern fn _chgsignl(c_longdouble) c_longdouble;
pub const struct_JSRuntime = opaque {
    pub const JS_SetRuntimeInfo = __root.JS_SetRuntimeInfo;
    pub const JS_SetMemoryLimit = __root.JS_SetMemoryLimit;
    pub const JS_SetDumpFlags = __root.JS_SetDumpFlags;
    pub const JS_GetDumpFlags = __root.JS_GetDumpFlags;
    pub const JS_GetGCThreshold = __root.JS_GetGCThreshold;
    pub const JS_SetGCThreshold = __root.JS_SetGCThreshold;
    pub const JS_SetMaxStackSize = __root.JS_SetMaxStackSize;
    pub const JS_UpdateStackTop = __root.JS_UpdateStackTop;
    pub const JS_FreeRuntime = __root.JS_FreeRuntime;
    pub const JS_GetRuntimeOpaque = __root.JS_GetRuntimeOpaque;
    pub const JS_SetRuntimeOpaque = __root.JS_SetRuntimeOpaque;
    pub const JS_AddRuntimeFinalizer = __root.JS_AddRuntimeFinalizer;
    pub const JS_MarkValue = __root.JS_MarkValue;
    pub const JS_RunGC = __root.JS_RunGC;
    pub const JS_IsLiveObject = __root.JS_IsLiveObject;
    pub const JS_NewContext = __root.JS_NewContext;
    pub const JS_NewContextRaw = __root.JS_NewContextRaw;
    pub const js_calloc_rt = __root.js_calloc_rt;
    pub const js_malloc_rt = __root.js_malloc_rt;
    pub const js_free_rt = __root.js_free_rt;
    pub const js_realloc_rt = __root.js_realloc_rt;
    pub const js_malloc_usable_size_rt = __root.js_malloc_usable_size_rt;
    pub const js_mallocz_rt = __root.js_mallocz_rt;
    pub const JS_ComputeMemoryUsage = __root.JS_ComputeMemoryUsage;
    pub const JS_DupAtomRT = __root.JS_DupAtomRT;
    pub const JS_FreeAtomRT = __root.JS_FreeAtomRT;
    pub const JS_NewClassID = __root.JS_NewClassID;
    pub const JS_NewClass = __root.JS_NewClass;
    pub const JS_IsRegisteredClass = __root.JS_IsRegisteredClass;
    pub const JS_GetClassName = __root.JS_GetClassName;
    pub const JS_FreeValueRT = __root.JS_FreeValueRT;
    pub const JS_DupValueRT = __root.JS_DupValueRT;
    pub const JS_FreeCStringRT = __root.JS_FreeCStringRT;
    pub const JS_FreeCStringRT_UTF16 = __root.JS_FreeCStringRT_UTF16;
    pub const JS_SetSharedArrayBufferFunctions = __root.JS_SetSharedArrayBufferFunctions;
    pub const JS_SetPromiseHook = __root.JS_SetPromiseHook;
    pub const JS_SetHostPromiseRejectionTracker = __root.JS_SetHostPromiseRejectionTracker;
    pub const JS_SetInterruptHandler = __root.JS_SetInterruptHandler;
    pub const JS_SetCanBlock = __root.JS_SetCanBlock;
    pub const JS_SetModuleLoaderFunc = __root.JS_SetModuleLoaderFunc;
    pub const JS_SetModuleLoaderFunc2 = __root.JS_SetModuleLoaderFunc2;
    pub const JS_SetModuleNormalizeFunc2 = __root.JS_SetModuleNormalizeFunc2;
    pub const JS_IsJobPending = __root.JS_IsJobPending;
    pub const JS_GetPendingJobContext = __root.JS_GetPendingJobContext;
    pub const JS_ExecutePendingJob = __root.JS_ExecutePendingJob;
    pub const SetRuntimeInfo = __root.JS_SetRuntimeInfo;
    pub const SetMemoryLimit = __root.JS_SetMemoryLimit;
    pub const SetDumpFlags = __root.JS_SetDumpFlags;
    pub const GetDumpFlags = __root.JS_GetDumpFlags;
    pub const GetGCThreshold = __root.JS_GetGCThreshold;
    pub const SetGCThreshold = __root.JS_SetGCThreshold;
    pub const SetMaxStackSize = __root.JS_SetMaxStackSize;
    pub const UpdateStackTop = __root.JS_UpdateStackTop;
    pub const FreeRuntime = __root.JS_FreeRuntime;
    pub const GetRuntimeOpaque = __root.JS_GetRuntimeOpaque;
    pub const SetRuntimeOpaque = __root.JS_SetRuntimeOpaque;
    pub const AddRuntimeFinalizer = __root.JS_AddRuntimeFinalizer;
    pub const MarkValue = __root.JS_MarkValue;
    pub const RunGC = __root.JS_RunGC;
    pub const IsLiveObject = __root.JS_IsLiveObject;
    pub const NewContext = __root.JS_NewContext;
    pub const NewContextRaw = __root.JS_NewContextRaw;
    pub const rt = __root.js_calloc_rt;
    pub const ComputeMemoryUsage = __root.JS_ComputeMemoryUsage;
    pub const DupAtomRT = __root.JS_DupAtomRT;
    pub const FreeAtomRT = __root.JS_FreeAtomRT;
    pub const NewClassID = __root.JS_NewClassID;
    pub const NewClass = __root.JS_NewClass;
    pub const IsRegisteredClass = __root.JS_IsRegisteredClass;
    pub const GetClassName = __root.JS_GetClassName;
    pub const FreeValueRT = __root.JS_FreeValueRT;
    pub const DupValueRT = __root.JS_DupValueRT;
    pub const FreeCStringRT = __root.JS_FreeCStringRT;
    pub const UTF16 = __root.JS_FreeCStringRT_UTF16;
    pub const SetSharedArrayBufferFunctions = __root.JS_SetSharedArrayBufferFunctions;
    pub const SetPromiseHook = __root.JS_SetPromiseHook;
    pub const SetHostPromiseRejectionTracker = __root.JS_SetHostPromiseRejectionTracker;
    pub const SetInterruptHandler = __root.JS_SetInterruptHandler;
    pub const SetCanBlock = __root.JS_SetCanBlock;
    pub const SetModuleLoaderFunc = __root.JS_SetModuleLoaderFunc;
    pub const SetModuleLoaderFunc2 = __root.JS_SetModuleLoaderFunc2;
    pub const SetModuleNormalizeFunc2 = __root.JS_SetModuleNormalizeFunc2;
    pub const IsJobPending = __root.JS_IsJobPending;
    pub const GetPendingJobContext = __root.JS_GetPendingJobContext;
    pub const ExecutePendingJob = __root.JS_ExecutePendingJob;
};
pub const JSRuntime = struct_JSRuntime;
pub const struct_JSContext = opaque {
    pub const JS_FreeContext = __root.JS_FreeContext;
    pub const JS_DupContext = __root.JS_DupContext;
    pub const JS_GetContextOpaque = __root.JS_GetContextOpaque;
    pub const JS_SetContextOpaque = __root.JS_SetContextOpaque;
    pub const JS_GetRuntime = __root.JS_GetRuntime;
    pub const JS_SetClassProto = __root.JS_SetClassProto;
    pub const JS_GetClassProto = __root.JS_GetClassProto;
    pub const JS_GetFunctionProto = __root.JS_GetFunctionProto;
    pub const JS_AddIntrinsicBaseObjects = __root.JS_AddIntrinsicBaseObjects;
    pub const JS_AddIntrinsicDate = __root.JS_AddIntrinsicDate;
    pub const JS_AddIntrinsicEval = __root.JS_AddIntrinsicEval;
    pub const JS_AddIntrinsicRegExpCompiler = __root.JS_AddIntrinsicRegExpCompiler;
    pub const JS_AddIntrinsicRegExp = __root.JS_AddIntrinsicRegExp;
    pub const JS_AddIntrinsicJSON = __root.JS_AddIntrinsicJSON;
    pub const JS_AddIntrinsicProxy = __root.JS_AddIntrinsicProxy;
    pub const JS_AddIntrinsicMapSet = __root.JS_AddIntrinsicMapSet;
    pub const JS_AddIntrinsicTypedArrays = __root.JS_AddIntrinsicTypedArrays;
    pub const JS_AddIntrinsicPromise = __root.JS_AddIntrinsicPromise;
    pub const JS_AddIntrinsicBigInt = __root.JS_AddIntrinsicBigInt;
    pub const JS_AddIntrinsicWeakRef = __root.JS_AddIntrinsicWeakRef;
    pub const JS_AddPerformance = __root.JS_AddPerformance;
    pub const JS_AddIntrinsicDOMException = __root.JS_AddIntrinsicDOMException;
    pub const JS_AddIntrinsicAToB = __root.JS_AddIntrinsicAToB;
    pub const JS_IsEqual = __root.JS_IsEqual;
    pub const JS_IsStrictEqual = __root.JS_IsStrictEqual;
    pub const JS_IsSameValue = __root.JS_IsSameValue;
    pub const JS_IsSameValueZero = __root.JS_IsSameValueZero;
    pub const js_string_codePointRange = __root.js_string_codePointRange;
    pub const js_calloc = __root.js_calloc;
    pub const js_malloc = __root.js_malloc;
    pub const js_free = __root.js_free;
    pub const js_realloc = __root.js_realloc;
    pub const js_malloc_usable_size = __root.js_malloc_usable_size;
    pub const js_mallocz = __root.js_mallocz;
    pub const js_strdup = __root.js_strdup;
    pub const js_strndup = __root.js_strndup;
    pub const JS_NewAtomLen = __root.JS_NewAtomLen;
    pub const JS_NewAtom = __root.JS_NewAtom;
    pub const JS_NewAtomUInt32 = __root.JS_NewAtomUInt32;
    pub const JS_DupAtom = __root.JS_DupAtom;
    pub const JS_FreeAtom = __root.JS_FreeAtom;
    pub const JS_AtomToValue = __root.JS_AtomToValue;
    pub const JS_AtomToString = __root.JS_AtomToString;
    pub const JS_AtomToCStringLen = __root.JS_AtomToCStringLen;
    pub const JS_AtomToCString = __root.JS_AtomToCString;
    pub const JS_ValueToAtom = __root.JS_ValueToAtom;
    pub const JS_NewBool = __root.JS_NewBool;
    pub const JS_NewInt32 = __root.JS_NewInt32;
    pub const JS_NewFloat64 = __root.JS_NewFloat64;
    pub const JS_NewCatchOffset = __root.JS_NewCatchOffset;
    pub const JS_NewInt64 = __root.JS_NewInt64;
    pub const JS_NewUint32 = __root.JS_NewUint32;
    pub const JS_NewUint64 = __root.JS_NewUint64;
    pub const JS_NewNumber = __root.JS_NewNumber;
    pub const JS_NewBigInt64 = __root.JS_NewBigInt64;
    pub const JS_NewBigUint64 = __root.JS_NewBigUint64;
    pub const JS_Throw = __root.JS_Throw;
    pub const JS_GetException = __root.JS_GetException;
    pub const JS_HasException = __root.JS_HasException;
    pub const JS_SetUncatchableError = __root.JS_SetUncatchableError;
    pub const JS_ClearUncatchableError = __root.JS_ClearUncatchableError;
    pub const JS_ResetUncatchableError = __root.JS_ResetUncatchableError;
    pub const JS_NewError = __root.JS_NewError;
    pub const JS_NewInternalError = __root.JS_NewInternalError;
    pub const JS_NewPlainError = __root.JS_NewPlainError;
    pub const JS_NewRangeError = __root.JS_NewRangeError;
    pub const JS_NewReferenceError = __root.JS_NewReferenceError;
    pub const JS_NewSyntaxError = __root.JS_NewSyntaxError;
    pub const JS_NewTypeError = __root.JS_NewTypeError;
    pub const JS_ThrowInternalError = __root.JS_ThrowInternalError;
    pub const JS_ThrowPlainError = __root.JS_ThrowPlainError;
    pub const JS_ThrowRangeError = __root.JS_ThrowRangeError;
    pub const JS_ThrowReferenceError = __root.JS_ThrowReferenceError;
    pub const JS_ThrowSyntaxError = __root.JS_ThrowSyntaxError;
    pub const JS_ThrowTypeError = __root.JS_ThrowTypeError;
    pub const JS_ThrowDOMException = __root.JS_ThrowDOMException;
    pub const JS_ThrowOutOfMemory = __root.JS_ThrowOutOfMemory;
    pub const JS_FreeValue = __root.JS_FreeValue;
    pub const JS_DupValue = __root.JS_DupValue;
    pub const JS_ToBool = __root.JS_ToBool;
    pub const JS_ToBoolean = __root.JS_ToBoolean;
    pub const JS_ToNumber = __root.JS_ToNumber;
    pub const JS_ToInt32 = __root.JS_ToInt32;
    pub const JS_ToUint32 = __root.JS_ToUint32;
    pub const JS_ToInt64 = __root.JS_ToInt64;
    pub const JS_ToIndex = __root.JS_ToIndex;
    pub const JS_ToFloat64 = __root.JS_ToFloat64;
    pub const JS_ToBigInt64 = __root.JS_ToBigInt64;
    pub const JS_ToBigUint64 = __root.JS_ToBigUint64;
    pub const JS_ToInt64Ext = __root.JS_ToInt64Ext;
    pub const JS_NewStringLen = __root.JS_NewStringLen;
    pub const JS_NewString = __root.JS_NewString;
    pub const JS_NewStringUTF16 = __root.JS_NewStringUTF16;
    pub const JS_NewAtomString = __root.JS_NewAtomString;
    pub const JS_ToString = __root.JS_ToString;
    pub const JS_ToPropertyKey = __root.JS_ToPropertyKey;
    pub const JS_ToCStringLen2 = __root.JS_ToCStringLen2;
    pub const JS_ToCStringLen = __root.JS_ToCStringLen;
    pub const JS_ToCString = __root.JS_ToCString;
    pub const JS_ToCStringLenUTF16 = __root.JS_ToCStringLenUTF16;
    pub const JS_ToCStringUTF16 = __root.JS_ToCStringUTF16;
    pub const JS_FreeCString = __root.JS_FreeCString;
    pub const JS_FreeCStringUTF16 = __root.JS_FreeCStringUTF16;
    pub const JS_NewObjectProtoClass = __root.JS_NewObjectProtoClass;
    pub const JS_NewObjectClass = __root.JS_NewObjectClass;
    pub const JS_NewObjectProto = __root.JS_NewObjectProto;
    pub const JS_NewObject = __root.JS_NewObject;
    pub const JS_NewObjectFrom = __root.JS_NewObjectFrom;
    pub const JS_NewObjectFromStr = __root.JS_NewObjectFromStr;
    pub const JS_ToObject = __root.JS_ToObject;
    pub const JS_ToObjectString = __root.JS_ToObjectString;
    pub const JS_IsFunction = __root.JS_IsFunction;
    pub const JS_IsConstructor = __root.JS_IsConstructor;
    pub const JS_SetConstructorBit = __root.JS_SetConstructorBit;
    pub const JS_NewArray = __root.JS_NewArray;
    pub const JS_NewArrayFrom = __root.JS_NewArrayFrom;
    pub const JS_GetProxyTarget = __root.JS_GetProxyTarget;
    pub const JS_GetProxyHandler = __root.JS_GetProxyHandler;
    pub const JS_NewProxy = __root.JS_NewProxy;
    pub const JS_NewDate = __root.JS_NewDate;
    pub const JS_GetProperty = __root.JS_GetProperty;
    pub const JS_GetPropertyUint32 = __root.JS_GetPropertyUint32;
    pub const JS_GetPropertyInt64 = __root.JS_GetPropertyInt64;
    pub const JS_GetPropertyStr = __root.JS_GetPropertyStr;
    pub const JS_GetPropertyValue = __root.JS_GetPropertyValue;
    pub const JS_SetProperty = __root.JS_SetProperty;
    pub const JS_SetPropertyUint32 = __root.JS_SetPropertyUint32;
    pub const JS_SetPropertyInt64 = __root.JS_SetPropertyInt64;
    pub const JS_SetPropertyStr = __root.JS_SetPropertyStr;
    pub const JS_SetPropertyValue = __root.JS_SetPropertyValue;
    pub const JS_HasProperty = __root.JS_HasProperty;
    pub const JS_IsExtensible = __root.JS_IsExtensible;
    pub const JS_PreventExtensions = __root.JS_PreventExtensions;
    pub const JS_DeleteProperty = __root.JS_DeleteProperty;
    pub const JS_SetPrototype = __root.JS_SetPrototype;
    pub const JS_GetPrototype = __root.JS_GetPrototype;
    pub const JS_GetLength = __root.JS_GetLength;
    pub const JS_SetLength = __root.JS_SetLength;
    pub const JS_SealObject = __root.JS_SealObject;
    pub const JS_FreezeObject = __root.JS_FreezeObject;
    pub const JS_GetOwnPropertyNames = __root.JS_GetOwnPropertyNames;
    pub const JS_GetOwnProperty = __root.JS_GetOwnProperty;
    pub const JS_FreePropertyEnum = __root.JS_FreePropertyEnum;
    pub const JS_Call = __root.JS_Call;
    pub const JS_Invoke = __root.JS_Invoke;
    pub const JS_CallConstructor = __root.JS_CallConstructor;
    pub const JS_CallConstructor2 = __root.JS_CallConstructor2;
    pub const JS_Eval = __root.JS_Eval;
    pub const JS_Eval2 = __root.JS_Eval2;
    pub const JS_EvalThis = __root.JS_EvalThis;
    pub const JS_EvalThis2 = __root.JS_EvalThis2;
    pub const JS_GetGlobalObject = __root.JS_GetGlobalObject;
    pub const JS_IsInstanceOf = __root.JS_IsInstanceOf;
    pub const JS_DefineProperty = __root.JS_DefineProperty;
    pub const JS_DefinePropertyValue = __root.JS_DefinePropertyValue;
    pub const JS_DefinePropertyValueUint32 = __root.JS_DefinePropertyValueUint32;
    pub const JS_DefinePropertyValueStr = __root.JS_DefinePropertyValueStr;
    pub const JS_DefinePropertyGetSet = __root.JS_DefinePropertyGetSet;
    pub const JS_GetOpaque2 = __root.JS_GetOpaque2;
    pub const JS_ParseJSON = __root.JS_ParseJSON;
    pub const JS_JSONStringify = __root.JS_JSONStringify;
    pub const JS_NewArrayBuffer = __root.JS_NewArrayBuffer;
    pub const JS_NewArrayBufferCopy = __root.JS_NewArrayBufferCopy;
    pub const JS_DetachArrayBuffer = __root.JS_DetachArrayBuffer;
    pub const JS_GetArrayBuffer = __root.JS_GetArrayBuffer;
    pub const JS_GetUint8Array = __root.JS_GetUint8Array;
    pub const JS_NewTypedArray = __root.JS_NewTypedArray;
    pub const JS_GetTypedArrayBuffer = __root.JS_GetTypedArrayBuffer;
    pub const JS_NewUint8Array = __root.JS_NewUint8Array;
    pub const JS_NewUint8ArrayCopy = __root.JS_NewUint8ArrayCopy;
    pub const JS_NewPromiseCapability = __root.JS_NewPromiseCapability;
    pub const JS_PromiseThen = __root.JS_PromiseThen;
    pub const JS_PromiseState = __root.JS_PromiseState;
    pub const JS_PromiseResult = __root.JS_PromiseResult;
    pub const JS_PromiseMarkAsHandled = __root.JS_PromiseMarkAsHandled;
    pub const JS_NewSettledPromise = __root.JS_NewSettledPromise;
    pub const JS_NewSymbol = __root.JS_NewSymbol;
    pub const JS_NewPrivateSymbol = __root.JS_NewPrivateSymbol;
    pub const JS_SetIsHTMLDDA = __root.JS_SetIsHTMLDDA;
    pub const JS_GetImportMeta = __root.JS_GetImportMeta;
    pub const JS_GetModuleName = __root.JS_GetModuleName;
    pub const JS_GetModuleNamespace = __root.JS_GetModuleNamespace;
    pub const JS_SetModulePrivateValue = __root.JS_SetModulePrivateValue;
    pub const JS_GetModulePrivateValue = __root.JS_GetModulePrivateValue;
    pub const JS_EnqueueJob = __root.JS_EnqueueJob;
    pub const JS_WriteObject = __root.JS_WriteObject;
    pub const JS_WriteObject2 = __root.JS_WriteObject2;
    pub const JS_ReadObject = __root.JS_ReadObject;
    pub const JS_ReadObject2 = __root.JS_ReadObject2;
    pub const JS_EvalFunction = __root.JS_EvalFunction;
    pub const JS_ResolveModule = __root.JS_ResolveModule;
    pub const JS_GetScriptOrModuleName = __root.JS_GetScriptOrModuleName;
    pub const JS_LoadModule = __root.JS_LoadModule;
    pub const JS_NewCFunction2 = __root.JS_NewCFunction2;
    pub const JS_NewCFunction3 = __root.JS_NewCFunction3;
    pub const JS_NewCFunctionData = __root.JS_NewCFunctionData;
    pub const JS_NewCFunctionData2 = __root.JS_NewCFunctionData2;
    pub const JS_NewCClosure = __root.JS_NewCClosure;
    pub const JS_NewCFunction = __root.JS_NewCFunction;
    pub const JS_NewCFunctionMagic = __root.JS_NewCFunctionMagic;
    pub const JS_SetConstructor = __root.JS_SetConstructor;
    pub const JS_SetPropertyFunctionList = __root.JS_SetPropertyFunctionList;
    pub const JS_NewCModule = __root.JS_NewCModule;
    pub const JS_AddModuleExport = __root.JS_AddModuleExport;
    pub const JS_AddModuleExportList = __root.JS_AddModuleExportList;
    pub const JS_SetModuleExport = __root.JS_SetModuleExport;
    pub const JS_SetModuleExportList = __root.JS_SetModuleExportList;
    pub const FreeContext = __root.JS_FreeContext;
    pub const DupContext = __root.JS_DupContext;
    pub const GetContextOpaque = __root.JS_GetContextOpaque;
    pub const SetContextOpaque = __root.JS_SetContextOpaque;
    pub const GetRuntime = __root.JS_GetRuntime;
    pub const SetClassProto = __root.JS_SetClassProto;
    pub const GetClassProto = __root.JS_GetClassProto;
    pub const GetFunctionProto = __root.JS_GetFunctionProto;
    pub const AddIntrinsicBaseObjects = __root.JS_AddIntrinsicBaseObjects;
    pub const AddIntrinsicDate = __root.JS_AddIntrinsicDate;
    pub const AddIntrinsicEval = __root.JS_AddIntrinsicEval;
    pub const AddIntrinsicRegExpCompiler = __root.JS_AddIntrinsicRegExpCompiler;
    pub const AddIntrinsicRegExp = __root.JS_AddIntrinsicRegExp;
    pub const AddIntrinsicJSON = __root.JS_AddIntrinsicJSON;
    pub const AddIntrinsicProxy = __root.JS_AddIntrinsicProxy;
    pub const AddIntrinsicMapSet = __root.JS_AddIntrinsicMapSet;
    pub const AddIntrinsicTypedArrays = __root.JS_AddIntrinsicTypedArrays;
    pub const AddIntrinsicPromise = __root.JS_AddIntrinsicPromise;
    pub const AddIntrinsicBigInt = __root.JS_AddIntrinsicBigInt;
    pub const AddIntrinsicWeakRef = __root.JS_AddIntrinsicWeakRef;
    pub const AddPerformance = __root.JS_AddPerformance;
    pub const AddIntrinsicDOMException = __root.JS_AddIntrinsicDOMException;
    pub const AddIntrinsicAToB = __root.JS_AddIntrinsicAToB;
    pub const IsEqual = __root.JS_IsEqual;
    pub const IsStrictEqual = __root.JS_IsStrictEqual;
    pub const IsSameValue = __root.JS_IsSameValue;
    pub const IsSameValueZero = __root.JS_IsSameValueZero;
    pub const codePointRange = __root.js_string_codePointRange;
    pub const calloc = __root.js_calloc;
    pub const malloc = __root.js_malloc;
    pub const free = __root.js_free;
    pub const realloc = __root.js_realloc;
    pub const size = __root.js_malloc_usable_size;
    pub const mallocz = __root.js_mallocz;
    pub const NewAtomLen = __root.JS_NewAtomLen;
    pub const NewAtom = __root.JS_NewAtom;
    pub const NewAtomUInt32 = __root.JS_NewAtomUInt32;
    pub const DupAtom = __root.JS_DupAtom;
    pub const FreeAtom = __root.JS_FreeAtom;
    pub const AtomToValue = __root.JS_AtomToValue;
    pub const AtomToString = __root.JS_AtomToString;
    pub const AtomToCStringLen = __root.JS_AtomToCStringLen;
    pub const AtomToCString = __root.JS_AtomToCString;
    pub const ValueToAtom = __root.JS_ValueToAtom;
    pub const NewBool = __root.JS_NewBool;
    pub const NewInt32 = __root.JS_NewInt32;
    pub const NewFloat64 = __root.JS_NewFloat64;
    pub const NewCatchOffset = __root.JS_NewCatchOffset;
    pub const NewInt64 = __root.JS_NewInt64;
    pub const NewUint32 = __root.JS_NewUint32;
    pub const NewUint64 = __root.JS_NewUint64;
    pub const NewNumber = __root.JS_NewNumber;
    pub const NewBigInt64 = __root.JS_NewBigInt64;
    pub const NewBigUint64 = __root.JS_NewBigUint64;
    pub const Throw = __root.JS_Throw;
    pub const GetException = __root.JS_GetException;
    pub const HasException = __root.JS_HasException;
    pub const SetUncatchableError = __root.JS_SetUncatchableError;
    pub const ClearUncatchableError = __root.JS_ClearUncatchableError;
    pub const ResetUncatchableError = __root.JS_ResetUncatchableError;
    pub const NewError = __root.JS_NewError;
    pub const NewInternalError = __root.JS_NewInternalError;
    pub const NewPlainError = __root.JS_NewPlainError;
    pub const NewRangeError = __root.JS_NewRangeError;
    pub const NewReferenceError = __root.JS_NewReferenceError;
    pub const NewSyntaxError = __root.JS_NewSyntaxError;
    pub const NewTypeError = __root.JS_NewTypeError;
    pub const ThrowInternalError = __root.JS_ThrowInternalError;
    pub const ThrowPlainError = __root.JS_ThrowPlainError;
    pub const ThrowRangeError = __root.JS_ThrowRangeError;
    pub const ThrowReferenceError = __root.JS_ThrowReferenceError;
    pub const ThrowSyntaxError = __root.JS_ThrowSyntaxError;
    pub const ThrowTypeError = __root.JS_ThrowTypeError;
    pub const ThrowDOMException = __root.JS_ThrowDOMException;
    pub const ThrowOutOfMemory = __root.JS_ThrowOutOfMemory;
    pub const FreeValue = __root.JS_FreeValue;
    pub const DupValue = __root.JS_DupValue;
    pub const ToBool = __root.JS_ToBool;
    pub const ToBoolean = __root.JS_ToBoolean;
    pub const ToNumber = __root.JS_ToNumber;
    pub const ToInt32 = __root.JS_ToInt32;
    pub const ToUint32 = __root.JS_ToUint32;
    pub const ToInt64 = __root.JS_ToInt64;
    pub const ToIndex = __root.JS_ToIndex;
    pub const ToFloat64 = __root.JS_ToFloat64;
    pub const ToBigInt64 = __root.JS_ToBigInt64;
    pub const ToBigUint64 = __root.JS_ToBigUint64;
    pub const ToInt64Ext = __root.JS_ToInt64Ext;
    pub const NewStringLen = __root.JS_NewStringLen;
    pub const NewString = __root.JS_NewString;
    pub const NewStringUTF16 = __root.JS_NewStringUTF16;
    pub const NewAtomString = __root.JS_NewAtomString;
    pub const ToString = __root.JS_ToString;
    pub const ToPropertyKey = __root.JS_ToPropertyKey;
    pub const ToCStringLen2 = __root.JS_ToCStringLen2;
    pub const ToCStringLen = __root.JS_ToCStringLen;
    pub const ToCString = __root.JS_ToCString;
    pub const ToCStringLenUTF16 = __root.JS_ToCStringLenUTF16;
    pub const ToCStringUTF16 = __root.JS_ToCStringUTF16;
    pub const FreeCString = __root.JS_FreeCString;
    pub const FreeCStringUTF16 = __root.JS_FreeCStringUTF16;
    pub const NewObjectProtoClass = __root.JS_NewObjectProtoClass;
    pub const NewObjectClass = __root.JS_NewObjectClass;
    pub const NewObjectProto = __root.JS_NewObjectProto;
    pub const NewObject = __root.JS_NewObject;
    pub const NewObjectFrom = __root.JS_NewObjectFrom;
    pub const NewObjectFromStr = __root.JS_NewObjectFromStr;
    pub const ToObject = __root.JS_ToObject;
    pub const ToObjectString = __root.JS_ToObjectString;
    pub const IsFunction = __root.JS_IsFunction;
    pub const IsConstructor = __root.JS_IsConstructor;
    pub const SetConstructorBit = __root.JS_SetConstructorBit;
    pub const NewArray = __root.JS_NewArray;
    pub const NewArrayFrom = __root.JS_NewArrayFrom;
    pub const GetProxyTarget = __root.JS_GetProxyTarget;
    pub const GetProxyHandler = __root.JS_GetProxyHandler;
    pub const NewProxy = __root.JS_NewProxy;
    pub const NewDate = __root.JS_NewDate;
    pub const GetProperty = __root.JS_GetProperty;
    pub const GetPropertyUint32 = __root.JS_GetPropertyUint32;
    pub const GetPropertyInt64 = __root.JS_GetPropertyInt64;
    pub const GetPropertyStr = __root.JS_GetPropertyStr;
    pub const GetPropertyValue = __root.JS_GetPropertyValue;
    pub const SetProperty = __root.JS_SetProperty;
    pub const SetPropertyUint32 = __root.JS_SetPropertyUint32;
    pub const SetPropertyInt64 = __root.JS_SetPropertyInt64;
    pub const SetPropertyStr = __root.JS_SetPropertyStr;
    pub const SetPropertyValue = __root.JS_SetPropertyValue;
    pub const HasProperty = __root.JS_HasProperty;
    pub const IsExtensible = __root.JS_IsExtensible;
    pub const PreventExtensions = __root.JS_PreventExtensions;
    pub const DeleteProperty = __root.JS_DeleteProperty;
    pub const SetPrototype = __root.JS_SetPrototype;
    pub const GetPrototype = __root.JS_GetPrototype;
    pub const GetLength = __root.JS_GetLength;
    pub const SetLength = __root.JS_SetLength;
    pub const SealObject = __root.JS_SealObject;
    pub const FreezeObject = __root.JS_FreezeObject;
    pub const GetOwnPropertyNames = __root.JS_GetOwnPropertyNames;
    pub const GetOwnProperty = __root.JS_GetOwnProperty;
    pub const FreePropertyEnum = __root.JS_FreePropertyEnum;
    pub const Call = __root.JS_Call;
    pub const Invoke = __root.JS_Invoke;
    pub const CallConstructor = __root.JS_CallConstructor;
    pub const CallConstructor2 = __root.JS_CallConstructor2;
    pub const Eval = __root.JS_Eval;
    pub const Eval2 = __root.JS_Eval2;
    pub const EvalThis = __root.JS_EvalThis;
    pub const EvalThis2 = __root.JS_EvalThis2;
    pub const GetGlobalObject = __root.JS_GetGlobalObject;
    pub const IsInstanceOf = __root.JS_IsInstanceOf;
    pub const DefineProperty = __root.JS_DefineProperty;
    pub const DefinePropertyValue = __root.JS_DefinePropertyValue;
    pub const DefinePropertyValueUint32 = __root.JS_DefinePropertyValueUint32;
    pub const DefinePropertyValueStr = __root.JS_DefinePropertyValueStr;
    pub const DefinePropertyGetSet = __root.JS_DefinePropertyGetSet;
    pub const GetOpaque2 = __root.JS_GetOpaque2;
    pub const ParseJSON = __root.JS_ParseJSON;
    pub const JSONStringify = __root.JS_JSONStringify;
    pub const NewArrayBuffer = __root.JS_NewArrayBuffer;
    pub const NewArrayBufferCopy = __root.JS_NewArrayBufferCopy;
    pub const DetachArrayBuffer = __root.JS_DetachArrayBuffer;
    pub const GetArrayBuffer = __root.JS_GetArrayBuffer;
    pub const GetUint8Array = __root.JS_GetUint8Array;
    pub const NewTypedArray = __root.JS_NewTypedArray;
    pub const GetTypedArrayBuffer = __root.JS_GetTypedArrayBuffer;
    pub const NewUint8Array = __root.JS_NewUint8Array;
    pub const NewUint8ArrayCopy = __root.JS_NewUint8ArrayCopy;
    pub const NewPromiseCapability = __root.JS_NewPromiseCapability;
    pub const PromiseThen = __root.JS_PromiseThen;
    pub const PromiseState = __root.JS_PromiseState;
    pub const PromiseResult = __root.JS_PromiseResult;
    pub const PromiseMarkAsHandled = __root.JS_PromiseMarkAsHandled;
    pub const NewSettledPromise = __root.JS_NewSettledPromise;
    pub const NewSymbol = __root.JS_NewSymbol;
    pub const NewPrivateSymbol = __root.JS_NewPrivateSymbol;
    pub const SetIsHTMLDDA = __root.JS_SetIsHTMLDDA;
    pub const GetImportMeta = __root.JS_GetImportMeta;
    pub const GetModuleName = __root.JS_GetModuleName;
    pub const GetModuleNamespace = __root.JS_GetModuleNamespace;
    pub const SetModulePrivateValue = __root.JS_SetModulePrivateValue;
    pub const GetModulePrivateValue = __root.JS_GetModulePrivateValue;
    pub const EnqueueJob = __root.JS_EnqueueJob;
    pub const WriteObject = __root.JS_WriteObject;
    pub const WriteObject2 = __root.JS_WriteObject2;
    pub const ReadObject = __root.JS_ReadObject;
    pub const ReadObject2 = __root.JS_ReadObject2;
    pub const EvalFunction = __root.JS_EvalFunction;
    pub const ResolveModule = __root.JS_ResolveModule;
    pub const GetScriptOrModuleName = __root.JS_GetScriptOrModuleName;
    pub const LoadModule = __root.JS_LoadModule;
    pub const NewCFunction2 = __root.JS_NewCFunction2;
    pub const NewCFunction3 = __root.JS_NewCFunction3;
    pub const NewCFunctionData = __root.JS_NewCFunctionData;
    pub const NewCFunctionData2 = __root.JS_NewCFunctionData2;
    pub const NewCClosure = __root.JS_NewCClosure;
    pub const NewCFunction = __root.JS_NewCFunction;
    pub const NewCFunctionMagic = __root.JS_NewCFunctionMagic;
    pub const SetConstructor = __root.JS_SetConstructor;
    pub const SetPropertyFunctionList = __root.JS_SetPropertyFunctionList;
    pub const NewCModule = __root.JS_NewCModule;
    pub const AddModuleExport = __root.JS_AddModuleExport;
    pub const AddModuleExportList = __root.JS_AddModuleExportList;
    pub const SetModuleExport = __root.JS_SetModuleExport;
    pub const SetModuleExportList = __root.JS_SetModuleExportList;
};
pub const JSContext = struct_JSContext;
pub const struct_JSObject = opaque {};
pub const JSObject = struct_JSObject;
pub const JSClassID = u32;
pub const JSAtom = u32;
pub const JS_TAG_FIRST: c_int = -9;
pub const JS_TAG_BIG_INT: c_int = -9;
pub const JS_TAG_SYMBOL: c_int = -8;
pub const JS_TAG_STRING: c_int = -7;
pub const JS_TAG_STRING_ROPE: c_int = -6;
pub const JS_TAG_MODULE: c_int = -3;
pub const JS_TAG_FUNCTION_BYTECODE: c_int = -2;
pub const JS_TAG_OBJECT: c_int = -1;
pub const JS_TAG_INT: c_int = 0;
pub const JS_TAG_BOOL: c_int = 1;
pub const JS_TAG_NULL: c_int = 2;
pub const JS_TAG_UNDEFINED: c_int = 3;
pub const JS_TAG_UNINITIALIZED: c_int = 4;
pub const JS_TAG_CATCH_OFFSET: c_int = 5;
pub const JS_TAG_EXCEPTION: c_int = 6;
pub const JS_TAG_SHORT_BIG_INT: c_int = 7;
pub const JS_TAG_FLOAT64: c_int = 8;
const enum_unnamed_3 = c_int;
pub const union_JSValueUnion = extern union {
    int32: i32,
    float64: f64,
    ptr: ?*anyopaque,
    short_big_int: i32,
};
pub const JSValueUnion = union_JSValueUnion;
pub const struct_JSValue = extern struct {
    u: JSValueUnion = @import("std").mem.zeroes(JSValueUnion),
    tag: i64 = 0,
    pub const JS_VALUE_IS_NAN = __root.JS_VALUE_IS_NAN;
    pub const JS_GetClassID = __root.JS_GetClassID;
    pub const JS_IsNumber = __root.JS_IsNumber;
    pub const JS_IsBigInt = __root.JS_IsBigInt;
    pub const JS_IsBool = __root.JS_IsBool;
    pub const JS_IsNull = __root.JS_IsNull;
    pub const JS_IsUndefined = __root.JS_IsUndefined;
    pub const JS_IsException = __root.JS_IsException;
    pub const JS_IsUninitialized = __root.JS_IsUninitialized;
    pub const JS_IsString = __root.JS_IsString;
    pub const JS_IsSymbol = __root.JS_IsSymbol;
    pub const JS_IsObject = __root.JS_IsObject;
    pub const JS_IsModule = __root.JS_IsModule;
    pub const JS_IsError = __root.JS_IsError;
    pub const JS_IsUncatchableError = __root.JS_IsUncatchableError;
    pub const JS_IsAsyncFunction = __root.JS_IsAsyncFunction;
    pub const JS_IsRegExp = __root.JS_IsRegExp;
    pub const JS_IsMap = __root.JS_IsMap;
    pub const JS_IsSet = __root.JS_IsSet;
    pub const JS_IsWeakRef = __root.JS_IsWeakRef;
    pub const JS_IsWeakSet = __root.JS_IsWeakSet;
    pub const JS_IsWeakMap = __root.JS_IsWeakMap;
    pub const JS_IsDataView = __root.JS_IsDataView;
    pub const JS_IsArray = __root.JS_IsArray;
    pub const JS_IsProxy = __root.JS_IsProxy;
    pub const JS_IsDate = __root.JS_IsDate;
    pub const JS_SetOpaque = __root.JS_SetOpaque;
    pub const JS_GetOpaque = __root.JS_GetOpaque;
    pub const JS_GetAnyOpaque = __root.JS_GetAnyOpaque;
    pub const JS_IsArrayBuffer = __root.JS_IsArrayBuffer;
    pub const JS_IsImmutableArrayBuffer = __root.JS_IsImmutableArrayBuffer;
    pub const JS_SetImmutableArrayBuffer = __root.JS_SetImmutableArrayBuffer;
    pub const JS_GetTypedArrayType = __root.JS_GetTypedArrayType;
    pub const JS_IsPromise = __root.JS_IsPromise;
    pub const GetClassID = __root.JS_GetClassID;
    pub const IsNumber = __root.JS_IsNumber;
    pub const IsBigInt = __root.JS_IsBigInt;
    pub const IsBool = __root.JS_IsBool;
    pub const IsNull = __root.JS_IsNull;
    pub const IsUndefined = __root.JS_IsUndefined;
    pub const IsException = __root.JS_IsException;
    pub const IsUninitialized = __root.JS_IsUninitialized;
    pub const IsString = __root.JS_IsString;
    pub const IsSymbol = __root.JS_IsSymbol;
    pub const IsObject = __root.JS_IsObject;
    pub const IsModule = __root.JS_IsModule;
    pub const IsError = __root.JS_IsError;
    pub const IsUncatchableError = __root.JS_IsUncatchableError;
    pub const IsAsyncFunction = __root.JS_IsAsyncFunction;
    pub const IsRegExp = __root.JS_IsRegExp;
    pub const IsMap = __root.JS_IsMap;
    pub const IsSet = __root.JS_IsSet;
    pub const IsWeakRef = __root.JS_IsWeakRef;
    pub const IsWeakSet = __root.JS_IsWeakSet;
    pub const IsWeakMap = __root.JS_IsWeakMap;
    pub const IsDataView = __root.JS_IsDataView;
    pub const IsArray = __root.JS_IsArray;
    pub const IsProxy = __root.JS_IsProxy;
    pub const IsDate = __root.JS_IsDate;
    pub const SetOpaque = __root.JS_SetOpaque;
    pub const GetOpaque = __root.JS_GetOpaque;
    pub const GetAnyOpaque = __root.JS_GetAnyOpaque;
    pub const IsArrayBuffer = __root.JS_IsArrayBuffer;
    pub const IsImmutableArrayBuffer = __root.JS_IsImmutableArrayBuffer;
    pub const SetImmutableArrayBuffer = __root.JS_SetImmutableArrayBuffer;
    pub const GetTypedArrayType = __root.JS_GetTypedArrayType;
    pub const IsPromise = __root.JS_IsPromise;
};
pub const JSValue = struct_JSValue;
pub fn __JS_NewFloat64(arg_d: f64) callconv(.c) JSValue {
    var d = arg_d;
    _ = &d;
    var v: JSValue = undefined;
    _ = &v;
    v.tag = JS_TAG_FLOAT64;
    v.u.float64 = d;
    return v;
}
pub fn JS_VALUE_IS_NAN(arg_v: JSValue) callconv(.c) bool {
    var v = arg_v;
    _ = &v;
    const union_unnamed_4 = extern union {
        d: f64,
        u64: u64,
    };
    _ = &union_unnamed_4;
    var u: union_unnamed_4 = undefined;
    _ = &u;
    if (v.tag != @as(i64, JS_TAG_FLOAT64)) return @as(c_int, 0) != 0;
    u.d = v.u.float64;
    return (u.u64 & @as(u64, 9223372036854775807)) > @as(u64, 9218868437227405312);
}
pub const JSCFunction = fn (ctx: ?*JSContext, this_val: JSValue, argc: c_int, argv: [*c]JSValue) callconv(.c) JSValue;
pub const JSCFunctionMagic = fn (ctx: ?*JSContext, this_val: JSValue, argc: c_int, argv: [*c]JSValue, magic: c_int) callconv(.c) JSValue;
pub const JSCFunctionData = fn (ctx: ?*JSContext, this_val: JSValue, argc: c_int, argv: [*c]JSValue, magic: c_int, func_data: [*c]JSValue) callconv(.c) JSValue;
pub const JSCClosure = fn (ctx: ?*JSContext, this_val: JSValue, argc: c_int, argv: [*c]JSValue, magic: c_int, @"opaque": ?*anyopaque) callconv(.c) JSValue;
pub const struct_JSMallocFunctions = extern struct {
    js_calloc: ?*const fn (@"opaque": ?*anyopaque, count: usize, size: usize) callconv(.c) ?*anyopaque = null,
    js_malloc: ?*const fn (@"opaque": ?*anyopaque, size: usize) callconv(.c) ?*anyopaque = null,
    js_free: ?*const fn (@"opaque": ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void = null,
    js_realloc: ?*const fn (@"opaque": ?*anyopaque, ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque = null,
    js_malloc_usable_size: ?*const fn (ptr: ?*const anyopaque) callconv(.c) usize = null,
    pub const JS_NewRuntime2 = __root.JS_NewRuntime2;
    pub const NewRuntime2 = __root.JS_NewRuntime2;
};
pub const JSMallocFunctions = struct_JSMallocFunctions;
pub const JSRuntimeFinalizer = fn (rt: ?*JSRuntime, arg: ?*anyopaque) callconv(.c) void;
pub const struct_JSGCObjectHeader = opaque {};
pub const JSGCObjectHeader = struct_JSGCObjectHeader;
pub extern fn JS_NewRuntime() ?*JSRuntime;
pub extern fn JS_SetRuntimeInfo(rt: ?*JSRuntime, info: [*c]const u8) void;
pub extern fn JS_SetMemoryLimit(rt: ?*JSRuntime, limit: usize) void;
pub extern fn JS_SetDumpFlags(rt: ?*JSRuntime, flags: u64) void;
pub extern fn JS_GetDumpFlags(rt: ?*JSRuntime) u64;
pub extern fn JS_GetGCThreshold(rt: ?*JSRuntime) usize;
pub extern fn JS_SetGCThreshold(rt: ?*JSRuntime, gc_threshold: usize) void;
pub extern fn JS_SetMaxStackSize(rt: ?*JSRuntime, stack_size: usize) void;
pub extern fn JS_UpdateStackTop(rt: ?*JSRuntime) void;
pub extern fn JS_NewRuntime2(mf: [*c]const JSMallocFunctions, @"opaque": ?*anyopaque) ?*JSRuntime;
pub extern fn JS_FreeRuntime(rt: ?*JSRuntime) void;
pub extern fn JS_GetRuntimeOpaque(rt: ?*JSRuntime) ?*anyopaque;
pub extern fn JS_SetRuntimeOpaque(rt: ?*JSRuntime, @"opaque": ?*anyopaque) void;
pub extern fn JS_AddRuntimeFinalizer(rt: ?*JSRuntime, finalizer: ?*const JSRuntimeFinalizer, arg: ?*anyopaque) c_int;
pub const JS_MarkFunc = fn (rt: ?*JSRuntime, gp: ?*JSGCObjectHeader) callconv(.c) void;
pub extern fn JS_MarkValue(rt: ?*JSRuntime, val: JSValue, mark_func: ?*const JS_MarkFunc) void;
pub extern fn JS_RunGC(rt: ?*JSRuntime) void;
pub extern fn JS_IsLiveObject(rt: ?*JSRuntime, obj: JSValue) bool;
pub extern fn JS_NewContext(rt: ?*JSRuntime) ?*JSContext;
pub extern fn JS_FreeContext(s: ?*JSContext) void;
pub extern fn JS_DupContext(ctx: ?*JSContext) ?*JSContext;
pub extern fn JS_GetContextOpaque(ctx: ?*JSContext) ?*anyopaque;
pub extern fn JS_SetContextOpaque(ctx: ?*JSContext, @"opaque": ?*anyopaque) void;
pub extern fn JS_GetRuntime(ctx: ?*JSContext) ?*JSRuntime;
pub extern fn JS_SetClassProto(ctx: ?*JSContext, class_id: JSClassID, obj: JSValue) void;
pub extern fn JS_GetClassProto(ctx: ?*JSContext, class_id: JSClassID) JSValue;
pub extern fn JS_GetFunctionProto(ctx: ?*JSContext) JSValue;
pub extern fn JS_NewContextRaw(rt: ?*JSRuntime) ?*JSContext;
pub extern fn JS_AddIntrinsicBaseObjects(ctx: ?*JSContext) c_int;
pub extern fn JS_AddIntrinsicDate(ctx: ?*JSContext) c_int;
pub extern fn JS_AddIntrinsicEval(ctx: ?*JSContext) c_int;
pub extern fn JS_AddIntrinsicRegExpCompiler(ctx: ?*JSContext) void;
pub extern fn JS_AddIntrinsicRegExp(ctx: ?*JSContext) c_int;
pub extern fn JS_AddIntrinsicJSON(ctx: ?*JSContext) c_int;
pub extern fn JS_AddIntrinsicProxy(ctx: ?*JSContext) c_int;
pub extern fn JS_AddIntrinsicMapSet(ctx: ?*JSContext) c_int;
pub extern fn JS_AddIntrinsicTypedArrays(ctx: ?*JSContext) c_int;
pub extern fn JS_AddIntrinsicPromise(ctx: ?*JSContext) c_int;
pub extern fn JS_AddIntrinsicBigInt(ctx: ?*JSContext) c_int;
pub extern fn JS_AddIntrinsicWeakRef(ctx: ?*JSContext) c_int;
pub extern fn JS_AddPerformance(ctx: ?*JSContext) c_int;
pub extern fn JS_AddIntrinsicDOMException(ctx: ?*JSContext) c_int;
pub extern fn JS_AddIntrinsicAToB(ctx: ?*JSContext) c_int;
pub extern fn JS_IsEqual(ctx: ?*JSContext, op1: JSValue, op2: JSValue) c_int;
pub extern fn JS_IsStrictEqual(ctx: ?*JSContext, op1: JSValue, op2: JSValue) bool;
pub extern fn JS_IsSameValue(ctx: ?*JSContext, op1: JSValue, op2: JSValue) bool;
pub extern fn JS_IsSameValueZero(ctx: ?*JSContext, op1: JSValue, op2: JSValue) bool;
pub extern fn js_string_codePointRange(ctx: ?*JSContext, this_val: JSValue, argc: c_int, argv: [*c]JSValue) JSValue;
pub extern fn js_calloc_rt(rt: ?*JSRuntime, count: usize, size: usize) ?*anyopaque;
pub extern fn js_malloc_rt(rt: ?*JSRuntime, size: usize) ?*anyopaque;
pub extern fn js_free_rt(rt: ?*JSRuntime, ptr: ?*anyopaque) void;
pub extern fn js_realloc_rt(rt: ?*JSRuntime, ptr: ?*anyopaque, size: usize) ?*anyopaque;
pub extern fn js_malloc_usable_size_rt(rt: ?*JSRuntime, ptr: ?*const anyopaque) usize;
pub extern fn js_mallocz_rt(rt: ?*JSRuntime, size: usize) ?*anyopaque;
pub extern fn js_calloc(ctx: ?*JSContext, count: usize, size: usize) ?*anyopaque;
pub extern fn js_malloc(ctx: ?*JSContext, size: usize) ?*anyopaque;
pub extern fn js_free(ctx: ?*JSContext, ptr: ?*anyopaque) void;
pub extern fn js_realloc(ctx: ?*JSContext, ptr: ?*anyopaque, size: usize) ?*anyopaque;
pub extern fn js_malloc_usable_size(ctx: ?*JSContext, ptr: ?*const anyopaque) usize;
pub extern fn js_mallocz(ctx: ?*JSContext, size: usize) ?*anyopaque;
pub extern fn js_strdup(ctx: ?*JSContext, str: [*c]const u8) [*c]u8;
pub extern fn js_strndup(ctx: ?*JSContext, s: [*c]const u8, n: usize) [*c]u8;
pub const struct_JSMemoryUsage = extern struct {
    malloc_size: i64 = 0,
    malloc_limit: i64 = 0,
    memory_used_size: i64 = 0,
    malloc_count: i64 = 0,
    memory_used_count: i64 = 0,
    atom_count: i64 = 0,
    atom_size: i64 = 0,
    str_count: i64 = 0,
    str_size: i64 = 0,
    obj_count: i64 = 0,
    obj_size: i64 = 0,
    prop_count: i64 = 0,
    prop_size: i64 = 0,
    shape_count: i64 = 0,
    shape_size: i64 = 0,
    js_func_count: i64 = 0,
    js_func_size: i64 = 0,
    js_func_code_size: i64 = 0,
    js_func_pc2line_count: i64 = 0,
    js_func_pc2line_size: i64 = 0,
    c_func_count: i64 = 0,
    array_count: i64 = 0,
    fast_array_count: i64 = 0,
    fast_array_elements: i64 = 0,
    binary_object_count: i64 = 0,
    binary_object_size: i64 = 0,
};
pub const JSMemoryUsage = struct_JSMemoryUsage;
pub extern fn JS_ComputeMemoryUsage(rt: ?*JSRuntime, s: [*c]JSMemoryUsage) void;
pub extern fn JS_DumpMemoryUsage(fp: [*c]FILE, s: [*c]const JSMemoryUsage, rt: ?*JSRuntime) void;
pub extern fn JS_NewAtomLen(ctx: ?*JSContext, str: [*c]const u8, len: usize) JSAtom;
pub extern fn JS_NewAtom(ctx: ?*JSContext, str: [*c]const u8) JSAtom;
pub extern fn JS_NewAtomUInt32(ctx: ?*JSContext, n: u32) JSAtom;
pub extern fn JS_DupAtom(ctx: ?*JSContext, v: JSAtom) JSAtom;
pub extern fn JS_DupAtomRT(rt: ?*JSRuntime, v: JSAtom) JSAtom;
pub extern fn JS_FreeAtom(ctx: ?*JSContext, v: JSAtom) void;
pub extern fn JS_FreeAtomRT(rt: ?*JSRuntime, v: JSAtom) void;
pub extern fn JS_AtomToValue(ctx: ?*JSContext, atom: JSAtom) JSValue;
pub extern fn JS_AtomToString(ctx: ?*JSContext, atom: JSAtom) JSValue;
pub extern fn JS_AtomToCStringLen(ctx: ?*JSContext, plen: [*c]usize, atom: JSAtom) [*c]const u8;
pub fn JS_AtomToCString(arg_ctx: ?*JSContext, arg_atom: JSAtom) callconv(.c) [*c]const u8 {
    var ctx = arg_ctx;
    _ = &ctx;
    var atom = arg_atom;
    _ = &atom;
    return JS_AtomToCStringLen(ctx, null, atom);
}
pub extern fn JS_ValueToAtom(ctx: ?*JSContext, val: JSValue) JSAtom;
pub const struct_JSPropertyEnum = extern struct {
    is_enumerable: bool = false,
    atom: JSAtom = 0,
};
pub const JSPropertyEnum = struct_JSPropertyEnum;
pub const struct_JSPropertyDescriptor = extern struct {
    flags: c_int = 0,
    value: JSValue = @import("std").mem.zeroes(JSValue),
    getter: JSValue = @import("std").mem.zeroes(JSValue),
    setter: JSValue = @import("std").mem.zeroes(JSValue),
};
pub const JSPropertyDescriptor = struct_JSPropertyDescriptor;
pub const struct_JSClassExoticMethods = extern struct {
    get_own_property: ?*const fn (ctx: ?*JSContext, desc: [*c]JSPropertyDescriptor, obj: JSValue, prop: JSAtom) callconv(.c) c_int = null,
    get_own_property_names: ?*const fn (ctx: ?*JSContext, ptab: [*c][*c]JSPropertyEnum, plen: [*c]u32, obj: JSValue) callconv(.c) c_int = null,
    delete_property: ?*const fn (ctx: ?*JSContext, obj: JSValue, prop: JSAtom) callconv(.c) c_int = null,
    define_own_property: ?*const fn (ctx: ?*JSContext, this_obj: JSValue, prop: JSAtom, val: JSValue, getter: JSValue, setter: JSValue, flags: c_int) callconv(.c) c_int = null,
    has_property: ?*const fn (ctx: ?*JSContext, obj: JSValue, atom: JSAtom) callconv(.c) c_int = null,
    get_property: ?*const fn (ctx: ?*JSContext, obj: JSValue, atom: JSAtom, receiver: JSValue) callconv(.c) JSValue = null,
    set_property: ?*const fn (ctx: ?*JSContext, obj: JSValue, atom: JSAtom, value: JSValue, receiver: JSValue, flags: c_int) callconv(.c) c_int = null,
};
pub const JSClassExoticMethods = struct_JSClassExoticMethods;
pub const JSClassFinalizer = fn (rt: ?*JSRuntime, val: JSValue) callconv(.c) void;
pub const JSClassGCMark = fn (rt: ?*JSRuntime, val: JSValue, mark_func: ?*const JS_MarkFunc) callconv(.c) void;
pub const JSClassCall = fn (ctx: ?*JSContext, func_obj: JSValue, this_val: JSValue, argc: c_int, argv: [*c]JSValue, flags: c_int) callconv(.c) JSValue;
pub const struct_JSClassDef = extern struct {
    class_name: [*c]const u8 = null,
    finalizer: ?*const JSClassFinalizer = null,
    gc_mark: ?*const JSClassGCMark = null,
    call: ?*const JSClassCall = null,
    exotic: [*c]JSClassExoticMethods = null,
};
pub const JSClassDef = struct_JSClassDef;
pub const struct_JSEvalOptions = extern struct {
    version: c_int = 0,
    eval_flags: c_int = 0,
    filename: [*c]const u8 = null,
    line_num: c_int = 0,
};
pub const JSEvalOptions = struct_JSEvalOptions;
pub extern fn JS_NewClassID(rt: ?*JSRuntime, pclass_id: [*c]JSClassID) JSClassID;
pub extern fn JS_GetClassID(v: JSValue) JSClassID;
pub extern fn JS_NewClass(rt: ?*JSRuntime, class_id: JSClassID, class_def: [*c]const JSClassDef) c_int;
pub extern fn JS_IsRegisteredClass(rt: ?*JSRuntime, class_id: JSClassID) bool;
pub extern fn JS_GetClassName(rt: ?*JSRuntime, class_id: JSClassID) JSAtom;
pub fn JS_NewBool(arg_ctx: ?*JSContext, arg_val: bool) callconv(.c) JSValue {
    var ctx = arg_ctx;
    _ = &ctx;
    var val = arg_val;
    _ = &val;
    _ = &ctx;
    return JSValue{
        .u = JSValueUnion{
            .int32 = @intFromBool(@as(c_int, @intFromBool(val)) != @as(c_int, 0)),
        },
        .tag = JS_TAG_BOOL,
    };
}
pub fn JS_NewInt32(arg_ctx: ?*JSContext, arg_val: i32) callconv(.c) JSValue {
    var ctx = arg_ctx;
    _ = &ctx;
    var val = arg_val;
    _ = &val;
    _ = &ctx;
    return JSValue{
        .u = JSValueUnion{
            .int32 = val,
        },
        .tag = JS_TAG_INT,
    };
}
pub fn JS_NewFloat64(arg_ctx: ?*JSContext, arg_val: f64) callconv(.c) JSValue {
    var ctx = arg_ctx;
    _ = &ctx;
    var val = arg_val;
    _ = &val;
    _ = &ctx;
    return __JS_NewFloat64(val);
}
pub fn JS_NewCatchOffset(arg_ctx: ?*JSContext, arg_val: i32) callconv(.c) JSValue {
    var ctx = arg_ctx;
    _ = &ctx;
    var val = arg_val;
    _ = &val;
    _ = &ctx;
    return JSValue{
        .u = JSValueUnion{
            .int32 = val,
        },
        .tag = JS_TAG_CATCH_OFFSET,
    };
}
pub fn JS_NewInt64(arg_ctx: ?*JSContext, arg_val: i64) callconv(.c) JSValue {
    var ctx = arg_ctx;
    _ = &ctx;
    var val = arg_val;
    _ = &val;
    var v: JSValue = undefined;
    _ = &v;
    if ((val >= @as(i64, -@as(c_int, 2147483647) - @as(c_int, 1))) and (val <= @as(i64, INT32_MAX))) {
        v = JS_NewInt32(ctx, @truncate(val));
    } else {
        v = JS_NewFloat64(ctx, @floatFromInt(val));
    }
    return v;
}
pub fn JS_NewUint32(arg_ctx: ?*JSContext, arg_val: u32) callconv(.c) JSValue {
    var ctx = arg_ctx;
    _ = &ctx;
    var val = arg_val;
    _ = &val;
    var v: JSValue = undefined;
    _ = &v;
    if (val <= @as(u32, INT32_MAX)) {
        v = JS_NewInt32(ctx, @bitCast(@as(c_uint, @truncate(val))));
    } else {
        v = JS_NewFloat64(ctx, @floatFromInt(val));
    }
    return v;
}
pub fn JS_NewUint64(arg_ctx: ?*JSContext, arg_val: u64) callconv(.c) JSValue {
    var ctx = arg_ctx;
    _ = &ctx;
    var val = arg_val;
    _ = &val;
    var v: JSValue = undefined;
    _ = &v;
    if (val <= @as(u64, INT32_MAX)) {
        v = JS_NewInt32(ctx, @bitCast(@as(c_uint, @truncate(val))));
    } else {
        v = JS_NewFloat64(ctx, @floatFromInt(val));
    }
    return v;
}
pub extern fn JS_NewNumber(ctx: ?*JSContext, d: f64) JSValue;
pub extern fn JS_NewBigInt64(ctx: ?*JSContext, v: i64) JSValue;
pub extern fn JS_NewBigUint64(ctx: ?*JSContext, v: u64) JSValue;
pub fn JS_IsNumber(arg_v: JSValue) callconv(.c) bool {
    var v = arg_v;
    _ = &v;
    var tag: c_int = @as(i32, @truncate(v.tag));
    _ = &tag;
    return (tag == JS_TAG_INT) or (@as(c_uint, @bitCast(@as(c_int, tag))) == @as(c_uint, JS_TAG_FLOAT64));
}
pub fn JS_IsBigInt(arg_v: JSValue) callconv(.c) bool {
    var v = arg_v;
    _ = &v;
    var tag: c_int = @as(i32, @truncate(v.tag));
    _ = &tag;
    return (tag == JS_TAG_BIG_INT) or (tag == JS_TAG_SHORT_BIG_INT);
}
pub fn JS_IsBool(arg_v: JSValue) callconv(.c) bool {
    var v = arg_v;
    _ = &v;
    return @as(i32, @truncate(v.tag)) == JS_TAG_BOOL;
}
pub fn JS_IsNull(arg_v: JSValue) callconv(.c) bool {
    var v = arg_v;
    _ = &v;
    return @as(i32, @truncate(v.tag)) == JS_TAG_NULL;
}
pub fn JS_IsUndefined(arg_v: JSValue) callconv(.c) bool {
    var v = arg_v;
    _ = &v;
    return @as(i32, @truncate(v.tag)) == JS_TAG_UNDEFINED;
}
pub fn JS_IsException(arg_v: JSValue) callconv(.c) bool {
    var v = arg_v;
    _ = &v;
    return @as(i32, @truncate(v.tag)) == JS_TAG_EXCEPTION;
}
pub fn JS_IsUninitialized(arg_v: JSValue) callconv(.c) bool {
    var v = arg_v;
    _ = &v;
    return @as(i32, @truncate(v.tag)) == JS_TAG_UNINITIALIZED;
}
pub fn JS_IsString(arg_v: JSValue) callconv(.c) bool {
    var v = arg_v;
    _ = &v;
    var tag: c_int = @as(i32, @truncate(v.tag));
    _ = &tag;
    return (tag == JS_TAG_STRING) or (tag == JS_TAG_STRING_ROPE);
}
pub fn JS_IsSymbol(arg_v: JSValue) callconv(.c) bool {
    var v = arg_v;
    _ = &v;
    return @as(i32, @truncate(v.tag)) == JS_TAG_SYMBOL;
}
pub fn JS_IsObject(arg_v: JSValue) callconv(.c) bool {
    var v = arg_v;
    _ = &v;
    return @as(i32, @truncate(v.tag)) == JS_TAG_OBJECT;
}
pub fn JS_IsModule(arg_v: JSValue) callconv(.c) bool {
    var v = arg_v;
    _ = &v;
    return @as(i32, @truncate(v.tag)) == JS_TAG_MODULE;
}
pub extern fn JS_Throw(ctx: ?*JSContext, obj: JSValue) JSValue;
pub extern fn JS_GetException(ctx: ?*JSContext) JSValue;
pub extern fn JS_HasException(ctx: ?*JSContext) bool;
pub extern fn JS_IsError(val: JSValue) bool;
pub extern fn JS_IsUncatchableError(val: JSValue) bool;
pub extern fn JS_SetUncatchableError(ctx: ?*JSContext, val: JSValue) void;
pub extern fn JS_ClearUncatchableError(ctx: ?*JSContext, val: JSValue) void;
pub extern fn JS_ResetUncatchableError(ctx: ?*JSContext) void;
pub extern fn JS_NewError(ctx: ?*JSContext) JSValue;
pub extern fn JS_NewInternalError(ctx: ?*JSContext, fmt: [*c]const u8, ...) JSValue;
pub extern fn JS_NewPlainError(ctx: ?*JSContext, fmt: [*c]const u8, ...) JSValue;
pub extern fn JS_NewRangeError(ctx: ?*JSContext, fmt: [*c]const u8, ...) JSValue;
pub extern fn JS_NewReferenceError(ctx: ?*JSContext, fmt: [*c]const u8, ...) JSValue;
pub extern fn JS_NewSyntaxError(ctx: ?*JSContext, fmt: [*c]const u8, ...) JSValue;
pub extern fn JS_NewTypeError(ctx: ?*JSContext, fmt: [*c]const u8, ...) JSValue;
pub extern fn JS_ThrowInternalError(ctx: ?*JSContext, fmt: [*c]const u8, ...) JSValue;
pub extern fn JS_ThrowPlainError(ctx: ?*JSContext, fmt: [*c]const u8, ...) JSValue;
pub extern fn JS_ThrowRangeError(ctx: ?*JSContext, fmt: [*c]const u8, ...) JSValue;
pub extern fn JS_ThrowReferenceError(ctx: ?*JSContext, fmt: [*c]const u8, ...) JSValue;
pub extern fn JS_ThrowSyntaxError(ctx: ?*JSContext, fmt: [*c]const u8, ...) JSValue;
pub extern fn JS_ThrowTypeError(ctx: ?*JSContext, fmt: [*c]const u8, ...) JSValue;
pub extern fn JS_ThrowDOMException(ctx: ?*JSContext, name: [*c]const u8, fmt: [*c]const u8, ...) JSValue;
pub extern fn JS_ThrowOutOfMemory(ctx: ?*JSContext) JSValue;
pub extern fn JS_FreeValue(ctx: ?*JSContext, v: JSValue) void;
pub extern fn JS_FreeValueRT(rt: ?*JSRuntime, v: JSValue) void;
pub extern fn JS_DupValue(ctx: ?*JSContext, v: JSValue) JSValue;
pub extern fn JS_DupValueRT(rt: ?*JSRuntime, v: JSValue) JSValue;
pub extern fn JS_ToBool(ctx: ?*JSContext, val: JSValue) c_int;
pub fn JS_ToBoolean(arg_ctx: ?*JSContext, arg_val: JSValue) callconv(.c) JSValue {
    var ctx = arg_ctx;
    _ = &ctx;
    var val = arg_val;
    _ = &val;
    return JS_NewBool(ctx, JS_ToBool(ctx, val) != 0);
}
pub extern fn JS_ToNumber(ctx: ?*JSContext, val: JSValue) JSValue;
pub extern fn JS_ToInt32(ctx: ?*JSContext, pres: [*c]i32, val: JSValue) c_int;
pub fn JS_ToUint32(arg_ctx: ?*JSContext, arg_pres: [*c]u32, arg_val: JSValue) callconv(.c) c_int {
    var ctx = arg_ctx;
    _ = &ctx;
    var pres = arg_pres;
    _ = &pres;
    var val = arg_val;
    _ = &val;
    return JS_ToInt32(ctx, @ptrCast(@alignCast(pres)), val);
}
pub extern fn JS_ToInt64(ctx: ?*JSContext, pres: [*c]i64, val: JSValue) c_int;
pub extern fn JS_ToIndex(ctx: ?*JSContext, plen: [*c]u64, val: JSValue) c_int;
pub extern fn JS_ToFloat64(ctx: ?*JSContext, pres: [*c]f64, val: JSValue) c_int;
pub extern fn JS_ToBigInt64(ctx: ?*JSContext, pres: [*c]i64, val: JSValue) c_int;
pub extern fn JS_ToBigUint64(ctx: ?*JSContext, pres: [*c]u64, val: JSValue) c_int;
pub extern fn JS_ToInt64Ext(ctx: ?*JSContext, pres: [*c]i64, val: JSValue) c_int;
pub extern fn JS_NewStringLen(ctx: ?*JSContext, str1: [*c]const u8, len1: usize) JSValue;
pub fn JS_NewString(arg_ctx: ?*JSContext, arg_str: [*c]const u8) callconv(.c) JSValue {
    var ctx = arg_ctx;
    _ = &ctx;
    var str = arg_str;
    _ = &str;
    return JS_NewStringLen(ctx, str, strlen(str));
}
pub extern fn JS_NewStringUTF16(ctx: ?*JSContext, buf: [*c]const u16, len: usize) JSValue;
pub extern fn JS_NewAtomString(ctx: ?*JSContext, str: [*c]const u8) JSValue;
pub extern fn JS_ToString(ctx: ?*JSContext, val: JSValue) JSValue;
pub extern fn JS_ToPropertyKey(ctx: ?*JSContext, val: JSValue) JSValue;
pub extern fn JS_ToCStringLen2(ctx: ?*JSContext, plen: [*c]usize, val1: JSValue, cesu8: bool) [*c]const u8;
pub fn JS_ToCStringLen(arg_ctx: ?*JSContext, arg_plen: [*c]usize, arg_val1: JSValue) callconv(.c) [*c]const u8 {
    var ctx = arg_ctx;
    _ = &ctx;
    var plen = arg_plen;
    _ = &plen;
    var val1 = arg_val1;
    _ = &val1;
    return JS_ToCStringLen2(ctx, plen, val1, @as(c_int, 0) != 0);
}
pub fn JS_ToCString(arg_ctx: ?*JSContext, arg_val1: JSValue) callconv(.c) [*c]const u8 {
    var ctx = arg_ctx;
    _ = &ctx;
    var val1 = arg_val1;
    _ = &val1;
    return JS_ToCStringLen2(ctx, null, val1, @as(c_int, 0) != 0);
}
pub extern fn JS_ToCStringLenUTF16(ctx: ?*JSContext, plen: [*c]usize, val1: JSValue) [*c]const u16;
pub fn JS_ToCStringUTF16(arg_ctx: ?*JSContext, arg_val1: JSValue) callconv(.c) [*c]const u16 {
    var ctx = arg_ctx;
    _ = &ctx;
    var val1 = arg_val1;
    _ = &val1;
    return JS_ToCStringLenUTF16(ctx, null, val1);
}
pub extern fn JS_FreeCString(ctx: ?*JSContext, ptr: [*c]const u8) void;
pub extern fn JS_FreeCStringRT(rt: ?*JSRuntime, ptr: [*c]const u8) void;
pub extern fn JS_FreeCStringUTF16(ctx: ?*JSContext, ptr: [*c]const u16) void;
pub extern fn JS_FreeCStringRT_UTF16(rt: ?*JSRuntime, ptr: [*c]const u16) void;
pub extern fn JS_NewObjectProtoClass(ctx: ?*JSContext, proto: JSValue, class_id: JSClassID) JSValue;
pub extern fn JS_NewObjectClass(ctx: ?*JSContext, class_id: JSClassID) JSValue;
pub extern fn JS_NewObjectProto(ctx: ?*JSContext, proto: JSValue) JSValue;
pub extern fn JS_NewObject(ctx: ?*JSContext) JSValue;
pub extern fn JS_NewObjectFrom(ctx: ?*JSContext, count: c_int, props: [*c]const JSAtom, values: [*c]const JSValue) JSValue;
pub extern fn JS_NewObjectFromStr(ctx: ?*JSContext, count: c_int, props: [*c][*c]const u8, values: [*c]const JSValue) JSValue;
pub extern fn JS_ToObject(ctx: ?*JSContext, val: JSValue) JSValue;
pub extern fn JS_ToObjectString(ctx: ?*JSContext, val: JSValue) JSValue;
pub extern fn JS_IsFunction(ctx: ?*JSContext, val: JSValue) bool;
pub extern fn JS_IsAsyncFunction(val: JSValue) bool;
pub extern fn JS_IsConstructor(ctx: ?*JSContext, val: JSValue) bool;
pub extern fn JS_SetConstructorBit(ctx: ?*JSContext, func_obj: JSValue, val: bool) bool;
pub extern fn JS_IsRegExp(val: JSValue) bool;
pub extern fn JS_IsMap(val: JSValue) bool;
pub extern fn JS_IsSet(val: JSValue) bool;
pub extern fn JS_IsWeakRef(val: JSValue) bool;
pub extern fn JS_IsWeakSet(val: JSValue) bool;
pub extern fn JS_IsWeakMap(val: JSValue) bool;
pub extern fn JS_IsDataView(val: JSValue) bool;
pub extern fn JS_NewArray(ctx: ?*JSContext) JSValue;
pub extern fn JS_NewArrayFrom(ctx: ?*JSContext, count: c_int, values: [*c]const JSValue) JSValue;
pub extern fn JS_IsArray(val: JSValue) bool;
pub extern fn JS_IsProxy(val: JSValue) bool;
pub extern fn JS_GetProxyTarget(ctx: ?*JSContext, proxy: JSValue) JSValue;
pub extern fn JS_GetProxyHandler(ctx: ?*JSContext, proxy: JSValue) JSValue;
pub extern fn JS_NewProxy(ctx: ?*JSContext, target: JSValue, handler: JSValue) JSValue;
pub extern fn JS_NewDate(ctx: ?*JSContext, epoch_ms: f64) JSValue;
pub extern fn JS_IsDate(v: JSValue) bool;
pub extern fn JS_GetProperty(ctx: ?*JSContext, this_obj: JSValue, prop: JSAtom) JSValue;
pub extern fn JS_GetPropertyUint32(ctx: ?*JSContext, this_obj: JSValue, idx: u32) JSValue;
pub extern fn JS_GetPropertyInt64(ctx: ?*JSContext, this_obj: JSValue, idx: i64) JSValue;
pub extern fn JS_GetPropertyStr(ctx: ?*JSContext, this_obj: JSValue, prop: [*c]const u8) JSValue;
pub extern fn JS_GetPropertyValue(ctx: ?*JSContext, this_obj: JSValue, prop: JSValue) JSValue;
pub extern fn JS_SetProperty(ctx: ?*JSContext, this_obj: JSValue, prop: JSAtom, val: JSValue) c_int;
pub extern fn JS_SetPropertyUint32(ctx: ?*JSContext, this_obj: JSValue, idx: u32, val: JSValue) c_int;
pub extern fn JS_SetPropertyInt64(ctx: ?*JSContext, this_obj: JSValue, idx: i64, val: JSValue) c_int;
pub extern fn JS_SetPropertyStr(ctx: ?*JSContext, this_obj: JSValue, prop: [*c]const u8, val: JSValue) c_int;
pub extern fn JS_SetPropertyValue(ctx: ?*JSContext, this_obj: JSValue, prop: JSValue, val: JSValue, flags: c_int) c_int;
pub extern fn JS_HasProperty(ctx: ?*JSContext, this_obj: JSValue, prop: JSAtom) c_int;
pub extern fn JS_IsExtensible(ctx: ?*JSContext, obj: JSValue) c_int;
pub extern fn JS_PreventExtensions(ctx: ?*JSContext, obj: JSValue) c_int;
pub extern fn JS_DeleteProperty(ctx: ?*JSContext, obj: JSValue, prop: JSAtom, flags: c_int) c_int;
pub extern fn JS_SetPrototype(ctx: ?*JSContext, obj: JSValue, proto_val: JSValue) c_int;
pub extern fn JS_GetPrototype(ctx: ?*JSContext, val: JSValue) JSValue;
pub extern fn JS_GetLength(ctx: ?*JSContext, obj: JSValue, pres: [*c]i64) c_int;
pub extern fn JS_SetLength(ctx: ?*JSContext, obj: JSValue, len: i64) c_int;
pub extern fn JS_SealObject(ctx: ?*JSContext, obj: JSValue) c_int;
pub extern fn JS_FreezeObject(ctx: ?*JSContext, obj: JSValue) c_int;
pub extern fn JS_GetOwnPropertyNames(ctx: ?*JSContext, ptab: [*c][*c]JSPropertyEnum, plen: [*c]u32, obj: JSValue, flags: c_int) c_int;
pub extern fn JS_GetOwnProperty(ctx: ?*JSContext, desc: [*c]JSPropertyDescriptor, obj: JSValue, prop: JSAtom) c_int;
pub extern fn JS_FreePropertyEnum(ctx: ?*JSContext, tab: [*c]JSPropertyEnum, len: u32) void;
pub extern fn JS_Call(ctx: ?*JSContext, func_obj: JSValue, this_obj: JSValue, argc: c_int, argv: [*c]JSValue) JSValue;
pub extern fn JS_Invoke(ctx: ?*JSContext, this_val: JSValue, atom: JSAtom, argc: c_int, argv: [*c]JSValue) JSValue;
pub extern fn JS_CallConstructor(ctx: ?*JSContext, func_obj: JSValue, argc: c_int, argv: [*c]JSValue) JSValue;
pub extern fn JS_CallConstructor2(ctx: ?*JSContext, func_obj: JSValue, new_target: JSValue, argc: c_int, argv: [*c]JSValue) JSValue;
pub extern fn JS_DetectModule(input: [*c]const u8, input_len: usize) bool;
pub extern fn JS_Eval(ctx: ?*JSContext, input: [*c]const u8, input_len: usize, filename: [*c]const u8, eval_flags: c_int) JSValue;
pub extern fn JS_Eval2(ctx: ?*JSContext, input: [*c]const u8, input_len: usize, options: [*c]JSEvalOptions) JSValue;
pub extern fn JS_EvalThis(ctx: ?*JSContext, this_obj: JSValue, input: [*c]const u8, input_len: usize, filename: [*c]const u8, eval_flags: c_int) JSValue;
pub extern fn JS_EvalThis2(ctx: ?*JSContext, this_obj: JSValue, input: [*c]const u8, input_len: usize, options: [*c]JSEvalOptions) JSValue;
pub extern fn JS_GetGlobalObject(ctx: ?*JSContext) JSValue;
pub extern fn JS_IsInstanceOf(ctx: ?*JSContext, val: JSValue, obj: JSValue) c_int;
pub extern fn JS_DefineProperty(ctx: ?*JSContext, this_obj: JSValue, prop: JSAtom, val: JSValue, getter: JSValue, setter: JSValue, flags: c_int) c_int;
pub extern fn JS_DefinePropertyValue(ctx: ?*JSContext, this_obj: JSValue, prop: JSAtom, val: JSValue, flags: c_int) c_int;
pub extern fn JS_DefinePropertyValueUint32(ctx: ?*JSContext, this_obj: JSValue, idx: u32, val: JSValue, flags: c_int) c_int;
pub extern fn JS_DefinePropertyValueStr(ctx: ?*JSContext, this_obj: JSValue, prop: [*c]const u8, val: JSValue, flags: c_int) c_int;
pub extern fn JS_DefinePropertyGetSet(ctx: ?*JSContext, this_obj: JSValue, prop: JSAtom, getter: JSValue, setter: JSValue, flags: c_int) c_int;
pub extern fn JS_SetOpaque(obj: JSValue, @"opaque": ?*anyopaque) c_int;
pub extern fn JS_GetOpaque(obj: JSValue, class_id: JSClassID) ?*anyopaque;
pub extern fn JS_GetOpaque2(ctx: ?*JSContext, obj: JSValue, class_id: JSClassID) ?*anyopaque;
pub extern fn JS_GetAnyOpaque(obj: JSValue, class_id: [*c]JSClassID) ?*anyopaque;
pub extern fn JS_ParseJSON(ctx: ?*JSContext, buf: [*c]const u8, buf_len: usize, filename: [*c]const u8) JSValue;
pub extern fn JS_JSONStringify(ctx: ?*JSContext, obj: JSValue, replacer: JSValue, space0: JSValue) JSValue;
pub const JSReallocArrayBufferDataFunc = fn (rt: ?*JSRuntime, @"opaque": ?*anyopaque, ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque;
pub extern fn JS_NewArrayBuffer(ctx: ?*JSContext, buf: [*c]u8, len: usize, max_len: usize, realloc_func: ?*const JSReallocArrayBufferDataFunc, @"opaque": ?*anyopaque, is_shared: bool) JSValue;
pub extern fn JS_NewArrayBufferCopy(ctx: ?*JSContext, buf: [*c]const u8, len: usize) JSValue;
pub extern fn JS_DetachArrayBuffer(ctx: ?*JSContext, obj: JSValue) void;
pub extern fn JS_GetArrayBuffer(ctx: ?*JSContext, psize: [*c]usize, obj: JSValue) [*c]u8;
pub extern fn JS_IsArrayBuffer(obj: JSValue) bool;
pub extern fn JS_IsImmutableArrayBuffer(obj: JSValue) c_int;
pub extern fn JS_SetImmutableArrayBuffer(obj: JSValue, immutable: bool) c_int;
pub extern fn JS_GetUint8Array(ctx: ?*JSContext, psize: [*c]usize, obj: JSValue) [*c]u8;
pub const JS_TYPED_ARRAY_UINT8C: c_int = 0;
pub const JS_TYPED_ARRAY_INT8: c_int = 1;
pub const JS_TYPED_ARRAY_UINT8: c_int = 2;
pub const JS_TYPED_ARRAY_INT16: c_int = 3;
pub const JS_TYPED_ARRAY_UINT16: c_int = 4;
pub const JS_TYPED_ARRAY_INT32: c_int = 5;
pub const JS_TYPED_ARRAY_UINT32: c_int = 6;
pub const JS_TYPED_ARRAY_BIG_INT64: c_int = 7;
pub const JS_TYPED_ARRAY_BIG_UINT64: c_int = 8;
pub const JS_TYPED_ARRAY_FLOAT16: c_int = 9;
pub const JS_TYPED_ARRAY_FLOAT32: c_int = 10;
pub const JS_TYPED_ARRAY_FLOAT64: c_int = 11;
pub const enum_JSTypedArrayEnum = c_uint;
pub const JSTypedArrayEnum = enum_JSTypedArrayEnum;
pub extern fn JS_NewTypedArray(ctx: ?*JSContext, argc: c_int, argv: [*c]JSValue, array_type: JSTypedArrayEnum) JSValue;
pub extern fn JS_GetTypedArrayBuffer(ctx: ?*JSContext, obj: JSValue, pbyte_offset: [*c]usize, pbyte_length: [*c]usize, pbytes_per_element: [*c]usize) JSValue;
pub extern fn JS_NewUint8Array(ctx: ?*JSContext, buf: [*c]u8, len: usize, realloc_func: ?*const JSReallocArrayBufferDataFunc, @"opaque": ?*anyopaque, is_shared: bool) JSValue;
pub extern fn JS_GetTypedArrayType(obj: JSValue) c_int;
pub extern fn JS_NewUint8ArrayCopy(ctx: ?*JSContext, buf: [*c]const u8, len: usize) JSValue;
pub const JSSharedArrayBufferFunctions = extern struct {
    sab_alloc: ?*const fn (@"opaque": ?*anyopaque, size: usize) callconv(.c) ?*anyopaque = null,
    sab_free: ?*const fn (@"opaque": ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void = null,
    sab_dup: ?*const fn (@"opaque": ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void = null,
    sab_opaque: ?*anyopaque = null,
};
pub extern fn JS_SetSharedArrayBufferFunctions(rt: ?*JSRuntime, sf: [*c]const JSSharedArrayBufferFunctions) void;
pub const JS_PROMISE_NOT_A_PROMISE: c_int = -1;
pub const JS_PROMISE_PENDING: c_int = 0;
pub const JS_PROMISE_FULFILLED: c_int = 1;
pub const JS_PROMISE_REJECTED: c_int = 2;
pub const enum_JSPromiseStateEnum = c_int;
pub const JSPromiseStateEnum = enum_JSPromiseStateEnum;
pub extern fn JS_NewPromiseCapability(ctx: ?*JSContext, resolving_funcs: [*c]JSValue) JSValue;
pub extern fn JS_PromiseThen(ctx: ?*JSContext, promise: JSValue, on_fulfilled: JSValue, on_rejected: JSValue) JSValue;
pub extern fn JS_PromiseState(ctx: ?*JSContext, promise: JSValue) JSPromiseStateEnum;
pub extern fn JS_PromiseResult(ctx: ?*JSContext, promise: JSValue) JSValue;
pub extern fn JS_IsPromise(val: JSValue) bool;
pub extern fn JS_PromiseMarkAsHandled(ctx: ?*JSContext, promise: JSValue) void;
pub extern fn JS_NewSettledPromise(ctx: ?*JSContext, is_reject: bool, value: JSValue) JSValue;
pub extern fn JS_NewSymbol(ctx: ?*JSContext, description: [*c]const u8, is_global: bool) JSValue;
pub extern fn JS_NewPrivateSymbol(ctx: ?*JSContext, description: [*c]const u8) JSValue;
pub const JS_PROMISE_HOOK_INIT: c_int = 0;
pub const JS_PROMISE_HOOK_BEFORE: c_int = 1;
pub const JS_PROMISE_HOOK_AFTER: c_int = 2;
pub const JS_PROMISE_HOOK_RESOLVE: c_int = 3;
pub const enum_JSPromiseHookType = c_uint;
pub const JSPromiseHookType = enum_JSPromiseHookType;
pub const JSPromiseHook = fn (ctx: ?*JSContext, @"type": JSPromiseHookType, promise: JSValue, parent_promise: JSValue, @"opaque": ?*anyopaque) callconv(.c) void;
pub extern fn JS_SetPromiseHook(rt: ?*JSRuntime, promise_hook: ?*const JSPromiseHook, @"opaque": ?*anyopaque) void;
pub const JSHostPromiseRejectionTracker = fn (ctx: ?*JSContext, promise: JSValue, reason: JSValue, is_handled: bool, @"opaque": ?*anyopaque) callconv(.c) void;
pub extern fn JS_SetHostPromiseRejectionTracker(rt: ?*JSRuntime, cb: ?*const JSHostPromiseRejectionTracker, @"opaque": ?*anyopaque) void;
pub const JSInterruptHandler = fn (rt: ?*JSRuntime, @"opaque": ?*anyopaque) callconv(.c) c_int;
pub extern fn JS_SetInterruptHandler(rt: ?*JSRuntime, cb: ?*const JSInterruptHandler, @"opaque": ?*anyopaque) void;
pub extern fn JS_SetCanBlock(rt: ?*JSRuntime, can_block: bool) void;
pub extern fn JS_SetIsHTMLDDA(ctx: ?*JSContext, obj: JSValue) void;
pub const struct_JSModuleDef = opaque {};
pub const JSModuleDef = struct_JSModuleDef;
pub const JSModuleNormalizeFunc = fn (ctx: ?*JSContext, module_base_name: [*c]const u8, module_name: [*c]const u8, @"opaque": ?*anyopaque) callconv(.c) [*c]u8;
pub const JSModuleNormalizeFunc2 = fn (ctx: ?*JSContext, module_base_name: [*c]const u8, module_name: [*c]const u8, attributes: JSValue, @"opaque": ?*anyopaque) callconv(.c) [*c]u8;
pub const JSModuleLoaderFunc = fn (ctx: ?*JSContext, module_name: [*c]const u8, @"opaque": ?*anyopaque) callconv(.c) ?*JSModuleDef;
pub const JSModuleLoaderFunc2 = fn (ctx: ?*JSContext, module_name: [*c]const u8, @"opaque": ?*anyopaque, attributes: JSValue) callconv(.c) ?*JSModuleDef;
pub const JSModuleCheckSupportedImportAttributes = fn (ctx: ?*JSContext, @"opaque": ?*anyopaque, attributes: JSValue) callconv(.c) c_int;
pub extern fn JS_SetModuleLoaderFunc(rt: ?*JSRuntime, module_normalize: ?*const JSModuleNormalizeFunc, module_loader: ?*const JSModuleLoaderFunc, @"opaque": ?*anyopaque) void;
pub extern fn JS_SetModuleLoaderFunc2(rt: ?*JSRuntime, module_normalize: ?*const JSModuleNormalizeFunc, module_loader: ?*const JSModuleLoaderFunc2, module_check_attrs: ?*const JSModuleCheckSupportedImportAttributes, @"opaque": ?*anyopaque) void;
pub extern fn JS_SetModuleNormalizeFunc2(rt: ?*JSRuntime, module_normalize: ?*const JSModuleNormalizeFunc2) void;
pub extern fn JS_GetImportMeta(ctx: ?*JSContext, m: ?*JSModuleDef) JSValue;
pub extern fn JS_GetModuleName(ctx: ?*JSContext, m: ?*JSModuleDef) JSAtom;
pub extern fn JS_GetModuleNamespace(ctx: ?*JSContext, m: ?*JSModuleDef) JSValue;
pub extern fn JS_SetModulePrivateValue(ctx: ?*JSContext, m: ?*JSModuleDef, val: JSValue) c_int;
pub extern fn JS_GetModulePrivateValue(ctx: ?*JSContext, m: ?*JSModuleDef) JSValue;
pub const JSJobFunc = fn (ctx: ?*JSContext, argc: c_int, argv: [*c]JSValue) callconv(.c) JSValue;
pub extern fn JS_EnqueueJob(ctx: ?*JSContext, job_func: ?*const JSJobFunc, argc: c_int, argv: [*c]JSValue) c_int;
pub extern fn JS_IsJobPending(rt: ?*JSRuntime) bool;
pub extern fn JS_GetPendingJobContext(rt: ?*JSRuntime) ?*JSContext;
pub extern fn JS_ExecutePendingJob(rt: ?*JSRuntime, pctx: [*c]?*JSContext) c_int;
pub const struct_JSSABTab = extern struct {
    tab: [*c][*c]u8 = null,
    len: usize = 0,
};
pub const JSSABTab = struct_JSSABTab;
pub extern fn JS_WriteObject(ctx: ?*JSContext, psize: [*c]usize, obj: JSValue, flags: c_int) [*c]u8;
pub extern fn JS_WriteObject2(ctx: ?*JSContext, psize: [*c]usize, obj: JSValue, flags: c_int, psab_tab: [*c]JSSABTab) [*c]u8;
pub extern fn JS_ReadObject(ctx: ?*JSContext, buf: [*c]const u8, buf_len: usize, flags: c_int) JSValue;
pub extern fn JS_ReadObject2(ctx: ?*JSContext, buf: [*c]const u8, buf_len: usize, flags: c_int, psab_tab: [*c]JSSABTab) JSValue;
pub extern fn JS_EvalFunction(ctx: ?*JSContext, fun_obj: JSValue) JSValue;
pub extern fn JS_ResolveModule(ctx: ?*JSContext, obj: JSValue) c_int;
pub extern fn JS_GetScriptOrModuleName(ctx: ?*JSContext, n_stack_levels: c_int) JSAtom;
pub extern fn JS_LoadModule(ctx: ?*JSContext, basename: [*c]const u8, filename: [*c]const u8) JSValue;
pub const JS_CFUNC_generic: c_int = 0;
pub const JS_CFUNC_generic_magic: c_int = 1;
pub const JS_CFUNC_constructor: c_int = 2;
pub const JS_CFUNC_constructor_magic: c_int = 3;
pub const JS_CFUNC_constructor_or_func: c_int = 4;
pub const JS_CFUNC_constructor_or_func_magic: c_int = 5;
pub const JS_CFUNC_f_f: c_int = 6;
pub const JS_CFUNC_f_f_f: c_int = 7;
pub const JS_CFUNC_getter: c_int = 8;
pub const JS_CFUNC_setter: c_int = 9;
pub const JS_CFUNC_getter_magic: c_int = 10;
pub const JS_CFUNC_setter_magic: c_int = 11;
pub const JS_CFUNC_iterator_next: c_int = 12;
pub const enum_JSCFunctionEnum = c_uint;
pub const JSCFunctionEnum = enum_JSCFunctionEnum;
pub const union_JSCFunctionType = extern union {
    generic: ?*const JSCFunction,
    generic_magic: ?*const fn (ctx: ?*JSContext, this_val: JSValue, argc: c_int, argv: [*c]JSValue, magic: c_int) callconv(.c) JSValue,
    constructor: ?*const JSCFunction,
    constructor_magic: ?*const fn (ctx: ?*JSContext, new_target: JSValue, argc: c_int, argv: [*c]JSValue, magic: c_int) callconv(.c) JSValue,
    constructor_or_func: ?*const JSCFunction,
    f_f: ?*const fn (f64) callconv(.c) f64,
    f_f_f: ?*const fn (f64, f64) callconv(.c) f64,
    getter: ?*const fn (ctx: ?*JSContext, this_val: JSValue) callconv(.c) JSValue,
    setter: ?*const fn (ctx: ?*JSContext, this_val: JSValue, val: JSValue) callconv(.c) JSValue,
    getter_magic: ?*const fn (ctx: ?*JSContext, this_val: JSValue, magic: c_int) callconv(.c) JSValue,
    setter_magic: ?*const fn (ctx: ?*JSContext, this_val: JSValue, val: JSValue, magic: c_int) callconv(.c) JSValue,
    iterator_next: ?*const fn (ctx: ?*JSContext, this_val: JSValue, argc: c_int, argv: [*c]JSValue, pdone: [*c]c_int, magic: c_int) callconv(.c) JSValue,
};
pub const JSCFunctionType = union_JSCFunctionType;
pub extern fn JS_NewCFunction2(ctx: ?*JSContext, func: ?*const JSCFunction, name: [*c]const u8, length: c_int, cproto: JSCFunctionEnum, magic: c_int) JSValue;
pub extern fn JS_NewCFunction3(ctx: ?*JSContext, func: ?*const JSCFunction, name: [*c]const u8, length: c_int, cproto: JSCFunctionEnum, magic: c_int, proto_val: JSValue, n_fields: c_int) JSValue;
pub extern fn JS_NewCFunctionData(ctx: ?*JSContext, func: ?*const JSCFunctionData, length: c_int, magic: c_int, data_len: c_int, data: [*c]JSValue) JSValue;
pub extern fn JS_NewCFunctionData2(ctx: ?*JSContext, func: ?*const JSCFunctionData, name: [*c]const u8, length: c_int, magic: c_int, data_len: c_int, data: [*c]JSValue) JSValue;
pub const JSCClosureFinalizerFunc = fn (?*anyopaque) callconv(.c) void;
pub extern fn JS_NewCClosure(ctx: ?*JSContext, func: ?*const JSCClosure, name: [*c]const u8, opaque_finalize: ?*const JSCClosureFinalizerFunc, length: c_int, magic: c_int, @"opaque": ?*anyopaque) JSValue;
pub fn JS_NewCFunction(arg_ctx: ?*JSContext, arg_func: ?*const JSCFunction, arg_name: [*c]const u8, arg_length: c_int) callconv(.c) JSValue {
    var ctx = arg_ctx;
    _ = &ctx;
    var func = arg_func;
    _ = &func;
    var name = arg_name;
    _ = &name;
    var length = arg_length;
    _ = &length;
    return JS_NewCFunction2(ctx, func, name, length, JS_CFUNC_generic, 0);
}
pub fn JS_NewCFunctionMagic(arg_ctx: ?*JSContext, arg_func: ?*const JSCFunctionMagic, arg_name: [*c]const u8, arg_length: c_int, arg_cproto: JSCFunctionEnum, arg_magic: c_int) callconv(.c) JSValue {
    var ctx = arg_ctx;
    _ = &ctx;
    var func = arg_func;
    _ = &func;
    var name = arg_name;
    _ = &name;
    var length = arg_length;
    _ = &length;
    var cproto = arg_cproto;
    _ = &cproto;
    var magic = arg_magic;
    _ = &magic;
    var ft: JSCFunctionType = undefined;
    _ = &ft;
    ft.generic_magic = func;
    return JS_NewCFunction2(ctx, ft.generic, name, length, cproto, magic);
}
pub extern fn JS_SetConstructor(ctx: ?*JSContext, func_obj: JSValue, proto: JSValue) c_int;
const struct_unnamed_6 = extern struct {
    length: u8 = 0,
    cproto: u8 = 0,
    cfunc: JSCFunctionType = @import("std").mem.zeroes(JSCFunctionType),
};
const struct_unnamed_7 = extern struct {
    get: JSCFunctionType = @import("std").mem.zeroes(JSCFunctionType),
    set: JSCFunctionType = @import("std").mem.zeroes(JSCFunctionType),
};
const struct_unnamed_8 = extern struct {
    name: [*c]const u8 = null,
    base: c_int = 0,
};
const struct_unnamed_9 = extern struct {
    tab: [*c]const struct_JSCFunctionListEntry = null,
    len: c_int = 0,
};
const union_unnamed_5 = extern union {
    func: struct_unnamed_6,
    getset: struct_unnamed_7,
    alias: struct_unnamed_8,
    prop_list: struct_unnamed_9,
    str: [*c]const u8,
    i32: i32,
    i64: i64,
    u64: u64,
    f64: f64,
};
pub const struct_JSCFunctionListEntry = extern struct {
    name: [*c]const u8 = null,
    prop_flags: u8 = 0,
    def_type: u8 = 0,
    magic: i16 = 0,
    u: union_unnamed_5 = @import("std").mem.zeroes(union_unnamed_5),
};
pub const JSCFunctionListEntry = struct_JSCFunctionListEntry;
pub extern fn JS_SetPropertyFunctionList(ctx: ?*JSContext, obj: JSValue, tab: [*c]const JSCFunctionListEntry, len: c_int) c_int;
pub const JSModuleInitFunc = fn (ctx: ?*JSContext, m: ?*JSModuleDef) callconv(.c) c_int;
pub extern fn JS_NewCModule(ctx: ?*JSContext, name_str: [*c]const u8, func: ?*const JSModuleInitFunc) ?*JSModuleDef;
pub extern fn JS_AddModuleExport(ctx: ?*JSContext, m: ?*JSModuleDef, name_str: [*c]const u8) c_int;
pub extern fn JS_AddModuleExportList(ctx: ?*JSContext, m: ?*JSModuleDef, tab: [*c]const JSCFunctionListEntry, len: c_int) c_int;
pub extern fn JS_SetModuleExport(ctx: ?*JSContext, m: ?*JSModuleDef, export_name: [*c]const u8, val: JSValue) c_int;
pub extern fn JS_SetModuleExportList(ctx: ?*JSContext, m: ?*JSModuleDef, tab: [*c]const JSCFunctionListEntry, len: c_int) c_int;
pub extern fn JS_GetVersion() [*c]const u8;
pub extern fn js_std_cmd(cmd: c_int, ...) usize;

pub const __VERSION__ = "Aro aro-zig";
pub const __Aro__ = "";
pub const __STDC__ = @as(c_int, 1);
pub const __STDC_HOSTED__ = @as(c_int, 1);
pub const __STDC_UTF_16__ = @as(c_int, 1);
pub const __STDC_UTF_32__ = @as(c_int, 1);
pub const __STDC_EMBED_NOT_FOUND__ = @as(c_int, 0);
pub const __STDC_EMBED_FOUND__ = @as(c_int, 1);
pub const __STDC_EMBED_EMPTY__ = @as(c_int, 2);
pub const __STDC_VERSION__ = @as(c_long, 201710);
pub const __GNUC__ = @as(c_int, 7);
pub const __GNUC_MINOR__ = @as(c_int, 1);
pub const __GNUC_PATCHLEVEL__ = @as(c_int, 0);
pub const __ARO_EMULATE_NO__ = @as(c_int, 0);
pub const __ARO_EMULATE_CLANG__ = @as(c_int, 1);
pub const __ARO_EMULATE_GCC__ = @as(c_int, 2);
pub const __ARO_EMULATE_MSVC__ = @as(c_int, 3);
pub const __ARO_EMULATE__ = __ARO_EMULATE_GCC__;
pub inline fn __building_module(x: anytype) @TypeOf(@as(c_int, 0)) {
    _ = &x;
    return @as(c_int, 0);
}
pub const _WIN32 = @as(c_int, 1);
pub const _WIN64 = @as(c_int, 1);
pub const WIN32 = @as(c_int, 1);
pub const __WIN32 = @as(c_int, 1);
pub const __WIN32__ = @as(c_int, 1);
pub const WINNT = @as(c_int, 1);
pub const __WINNT = @as(c_int, 1);
pub const __WINNT__ = @as(c_int, 1);
pub const WIN64 = @as(c_int, 1);
pub const __WIN64 = @as(c_int, 1);
pub const __WIN64__ = @as(c_int, 1);
pub const __MINGW64__ = @as(c_int, 1);
pub const __MSVCRT__ = @as(c_int, 1);
pub const __MINGW32__ = @as(c_int, 1);
pub const __declspec = @compileError("unable to translate C expr: unexpected token '__attribute__'");
// <builtin>:34:9
pub const _cdecl = @compileError("unable to translate macro: undefined identifier `__cdecl__`");
// <builtin>:35:9
pub const __cdecl = @compileError("unable to translate macro: undefined identifier `__cdecl__`");
// <builtin>:36:9
pub const _stdcall = @compileError("unable to translate macro: undefined identifier `__stdcall__`");
// <builtin>:37:9
pub const __stdcall = @compileError("unable to translate macro: undefined identifier `__stdcall__`");
// <builtin>:38:9
pub const _fastcall = @compileError("unable to translate macro: undefined identifier `__fastcall__`");
// <builtin>:39:9
pub const __fastcall = @compileError("unable to translate macro: undefined identifier `__fastcall__`");
// <builtin>:40:9
pub const _thiscall = @compileError("unable to translate macro: undefined identifier `__thiscall__`");
// <builtin>:41:9
pub const __thiscall = @compileError("unable to translate macro: undefined identifier `__thiscall__`");
// <builtin>:42:9
pub const __code_model_small__ = @as(c_int, 1);
pub const __amd64__ = @as(c_int, 1);
pub const __amd64 = @as(c_int, 1);
pub const __x86_64__ = @as(c_int, 1);
pub const __x86_64 = @as(c_int, 1);
pub const __SEG_GS = @as(c_int, 1);
pub const __SEG_FS = @as(c_int, 1);
pub const __seg_gs = @compileError("unable to translate macro: undefined identifier `address_space`");
// <builtin>:50:9
pub const __seg_fs = @compileError("unable to translate macro: undefined identifier `address_space`");
// <builtin>:51:9
pub const __LAHF_SAHF__ = @as(c_int, 1);
pub const __AES__ = @as(c_int, 1);
pub const __VAES__ = @as(c_int, 1);
pub const __PCLMUL__ = @as(c_int, 1);
pub const __VPCLMULQDQ__ = @as(c_int, 1);
pub const __LZCNT__ = @as(c_int, 1);
pub const __RDRND__ = @as(c_int, 1);
pub const __FSGSBASE__ = @as(c_int, 1);
pub const __BMI__ = @as(c_int, 1);
pub const __BMI2__ = @as(c_int, 1);
pub const __POPCNT__ = @as(c_int, 1);
pub const __PRFCHW__ = @as(c_int, 1);
pub const __RDSEED__ = @as(c_int, 1);
pub const __ADX__ = @as(c_int, 1);
pub const __MWAITX__ = @as(c_int, 1);
pub const __MOVBE__ = @as(c_int, 1);
pub const __SSE4A__ = @as(c_int, 1);
pub const __FMA__ = @as(c_int, 1);
pub const __F16C__ = @as(c_int, 1);
pub const __GFNI__ = @as(c_int, 1);
pub const __AVX512CD__ = @as(c_int, 1);
pub const __AVX512VPOPCNTDQ__ = @as(c_int, 1);
pub const __AVX512VNNI__ = @as(c_int, 1);
pub const __AVX512BF16__ = @as(c_int, 1);
pub const __AVX512DQ__ = @as(c_int, 1);
pub const __AVX512BITALG__ = @as(c_int, 1);
pub const __AVX512BW__ = @as(c_int, 1);
pub const __AVX512VL__ = @as(c_int, 1);
pub const __EVEX256__ = @as(c_int, 1);
pub const __AVX512VBMI__ = @as(c_int, 1);
pub const __AVX512VBMI2__ = @as(c_int, 1);
pub const __AVX512IFMA__ = @as(c_int, 1);
pub const __AVX512VP2INTERSECT__ = @as(c_int, 1);
pub const __SHA__ = @as(c_int, 1);
pub const __FXSR__ = @as(c_int, 1);
pub const __XSAVE__ = @as(c_int, 1);
pub const __XSAVEOPT__ = @as(c_int, 1);
pub const __XSAVEC__ = @as(c_int, 1);
pub const __XSAVES__ = @as(c_int, 1);
pub const __CLFLUSHOPT__ = @as(c_int, 1);
pub const __CLWB__ = @as(c_int, 1);
pub const __WBNOINVD__ = @as(c_int, 1);
pub const __SHSTK__ = @as(c_int, 1);
pub const __CLZERO__ = @as(c_int, 1);
pub const __RDPID__ = @as(c_int, 1);
pub const __RDPRU__ = @as(c_int, 1);
pub const __INVPCID__ = @as(c_int, 1);
pub const __AVXVNNI__ = @as(c_int, 1);
pub const __CRC32__ = @as(c_int, 1);
pub const __AVX512F__ = @as(c_int, 1);
pub const __AVX2__ = @as(c_int, 1);
pub const __AVX__ = @as(c_int, 1);
pub const __SSE4_2__ = @as(c_int, 1);
pub const __SSE4_1__ = @as(c_int, 1);
pub const __SSSE3__ = @as(c_int, 1);
pub const __SSE3__ = @as(c_int, 1);
pub const __SSE2__ = @as(c_int, 1);
pub const __SSE__ = @as(c_int, 1);
pub const __SSE_MATH__ = @as(c_int, 1);
pub const __MMX__ = @as(c_int, 1);
pub const __GCC_HAVE_SYNC_COMPARE_AND_SWAP_8 = @as(c_int, 1);
pub const __ORDER_LITTLE_ENDIAN__ = @as(c_int, 1234);
pub const __ORDER_BIG_ENDIAN__ = @as(c_int, 4321);
pub const __ORDER_PDP_ENDIAN__ = @as(c_int, 3412);
pub const __BYTE_ORDER__ = __ORDER_LITTLE_ENDIAN__;
pub const __LITTLE_ENDIAN__ = @as(c_int, 1);
pub const __ATOMIC_RELAXED = @as(c_int, 0);
pub const __ATOMIC_CONSUME = @as(c_int, 1);
pub const __ATOMIC_ACQUIRE = @as(c_int, 2);
pub const __ATOMIC_RELEASE = @as(c_int, 3);
pub const __ATOMIC_ACQ_REL = @as(c_int, 4);
pub const __ATOMIC_SEQ_CST = @as(c_int, 5);
pub const __ATOMIC_BOOL_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_CHAR_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_CHAR16_T_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_CHAR32_T_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_WCHAR_T_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_WINT_T_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_SHORT_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_INT_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_LONG_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_LLONG_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_POINTER_LOCK_FREE = @as(c_int, 1);
pub const __WCHAR_UNSIGNED__ = @as(c_int, 1);
pub const __WINT_UNSIGNED__ = @as(c_int, 1);
pub const __CHAR_BIT__ = @as(c_int, 8);
pub const __BOOL_WIDTH__ = @as(c_int, 8);
pub const __SCHAR_MAX__ = @as(c_int, 127);
pub const __SCHAR_WIDTH__ = @as(c_int, 8);
pub const __SHRT_MAX__ = @as(c_int, 32767);
pub const __SHRT_WIDTH__ = @as(c_int, 16);
pub const __INT_MAX__ = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __INT_WIDTH__ = @as(c_int, 32);
pub const __LONG_MAX__ = @as(c_long, 2147483647);
pub const __LONG_WIDTH__ = @as(c_int, 32);
pub const __LONG_LONG_MAX__ = @as(c_longlong, 9223372036854775807);
pub const __LONG_LONG_WIDTH__ = @as(c_int, 64);
pub const __WCHAR_MAX__ = __helpers.promoteIntLiteral(c_int, 65535, .decimal);
pub const __WCHAR_WIDTH__ = @as(c_int, 16);
pub const __WINT_MAX__ = __helpers.promoteIntLiteral(c_int, 65535, .decimal);
pub const __WINT_WIDTH__ = @as(c_int, 16);
pub const __INTMAX_MAX__ = @as(c_longlong, 9223372036854775807);
pub const __INTMAX_WIDTH__ = @as(c_int, 64);
pub const __SIZE_MAX__ = @as(c_ulonglong, 18446744073709551615);
pub const __SIZE_WIDTH__ = @as(c_int, 64);
pub const __UINTMAX_MAX__ = @as(c_ulonglong, 18446744073709551615);
pub const __UINTMAX_WIDTH__ = @as(c_int, 64);
pub const __PTRDIFF_MAX__ = @as(c_longlong, 9223372036854775807);
pub const __PTRDIFF_WIDTH__ = @as(c_int, 64);
pub const __INTPTR_MAX__ = @as(c_longlong, 9223372036854775807);
pub const __INTPTR_WIDTH__ = @as(c_int, 64);
pub const __UINTPTR_MAX__ = @as(c_ulonglong, 18446744073709551615);
pub const __UINTPTR_WIDTH__ = @as(c_int, 64);
pub const __SIG_ATOMIC_MAX__ = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __SIG_ATOMIC_WIDTH__ = @as(c_int, 32);
pub const __BITINT_MAXWIDTH__ = __helpers.promoteIntLiteral(c_int, 65535, .decimal);
pub const __SIZEOF_FLOAT__ = @as(c_int, 4);
pub const __SIZEOF_DOUBLE__ = @as(c_int, 8);
pub const __SIZEOF_LONG_DOUBLE__ = @as(c_int, 10);
pub const __SIZEOF_SHORT__ = @as(c_int, 2);
pub const __SIZEOF_INT__ = @as(c_int, 4);
pub const __SIZEOF_LONG__ = @as(c_int, 4);
pub const __SIZEOF_LONG_LONG__ = @as(c_int, 8);
pub const __SIZEOF_POINTER__ = @as(c_int, 8);
pub const __SIZEOF_PTRDIFF_T__ = @as(c_int, 8);
pub const __SIZEOF_SIZE_T__ = @as(c_int, 8);
pub const __SIZEOF_WCHAR_T__ = @as(c_int, 2);
pub const __SIZEOF_WINT_T__ = @as(c_int, 2);
pub const __SIZEOF_INT128__ = @as(c_int, 16);
pub const __INTPTR_TYPE__ = c_longlong;
pub const __UINTPTR_TYPE__ = c_ulonglong;
pub const __INTMAX_TYPE__ = c_longlong;
pub const __INTMAX_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `LL`");
// <builtin>:185:9
pub const __INTMAX_C = __helpers.LL_SUFFIX;
pub const __UINTMAX_TYPE__ = c_ulonglong;
pub const __UINTMAX_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `ULL`");
// <builtin>:188:9
pub const __UINTMAX_C = __helpers.ULL_SUFFIX;
pub const __PTRDIFF_TYPE__ = c_longlong;
pub const __SIZE_TYPE__ = c_ulonglong;
pub const __WCHAR_TYPE__ = c_ushort;
pub const __WINT_TYPE__ = c_ushort;
pub const __CHAR16_TYPE__ = c_ushort;
pub const __CHAR32_TYPE__ = c_uint;
pub const __INT8_TYPE__ = i8;
pub const __INT8_FMTd__ = "hhd";
pub const __INT8_FMTi__ = "hhi";
pub const __INT8_C_SUFFIX__ = "";
pub inline fn __INT8_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub const __INT16_TYPE__ = c_short;
pub const __INT16_FMTd__ = "hd";
pub const __INT16_FMTi__ = "hi";
pub const __INT16_C_SUFFIX__ = "";
pub inline fn __INT16_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub const __INT32_TYPE__ = c_int;
pub const __INT32_FMTd__ = "d";
pub const __INT32_FMTi__ = "i";
pub const __INT32_C_SUFFIX__ = "";
pub inline fn __INT32_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub const __INT64_TYPE__ = c_longlong;
pub const __INT64_FMTd__ = "lld";
pub const __INT64_FMTi__ = "lli";
pub const __INT64_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `LL`");
// <builtin>:214:9
pub const __INT64_C = __helpers.LL_SUFFIX;
pub const __UINT8_TYPE__ = u8;
pub const __UINT8_FMTo__ = "hho";
pub const __UINT8_FMTu__ = "hhu";
pub const __UINT8_FMTx__ = "hhx";
pub const __UINT8_FMTX__ = "hhX";
pub const __UINT8_C_SUFFIX__ = "";
pub inline fn __UINT8_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub const __UINT8_MAX__ = @as(c_int, 255);
pub const __INT8_MAX__ = @as(c_int, 127);
pub const __UINT16_TYPE__ = c_ushort;
pub const __UINT16_FMTo__ = "ho";
pub const __UINT16_FMTu__ = "hu";
pub const __UINT16_FMTx__ = "hx";
pub const __UINT16_FMTX__ = "hX";
pub const __UINT16_C_SUFFIX__ = "";
pub inline fn __UINT16_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub const __UINT16_MAX__ = __helpers.promoteIntLiteral(c_int, 65535, .decimal);
pub const __INT16_MAX__ = @as(c_int, 32767);
pub const __UINT32_TYPE__ = c_uint;
pub const __UINT32_FMTo__ = "o";
pub const __UINT32_FMTu__ = "u";
pub const __UINT32_FMTx__ = "x";
pub const __UINT32_FMTX__ = "X";
pub const __UINT32_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `U`");
// <builtin>:239:9
pub const __UINT32_C = __helpers.U_SUFFIX;
pub const __UINT32_MAX__ = __helpers.promoteIntLiteral(c_uint, 4294967295, .decimal);
pub const __INT32_MAX__ = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __UINT64_TYPE__ = c_ulonglong;
pub const __UINT64_FMTo__ = "llo";
pub const __UINT64_FMTu__ = "llu";
pub const __UINT64_FMTx__ = "llx";
pub const __UINT64_FMTX__ = "llX";
pub const __UINT64_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `ULL`");
// <builtin>:248:9
pub const __UINT64_C = __helpers.ULL_SUFFIX;
pub const __UINT64_MAX__ = @as(c_ulonglong, 18446744073709551615);
pub const __INT64_MAX__ = @as(c_longlong, 9223372036854775807);
pub const __INT_LEAST8_TYPE__ = i8;
pub const __INT_LEAST8_MAX__ = @as(c_int, 127);
pub const __INT_LEAST8_WIDTH__ = @as(c_int, 8);
pub const INT_LEAST8_FMTd__ = "hhd";
pub const INT_LEAST8_FMTi__ = "hhi";
pub const __UINT_LEAST8_TYPE__ = u8;
pub const __UINT_LEAST8_MAX__ = @as(c_int, 255);
pub const UINT_LEAST8_FMTo__ = "hho";
pub const UINT_LEAST8_FMTu__ = "hhu";
pub const UINT_LEAST8_FMTx__ = "hhx";
pub const UINT_LEAST8_FMTX__ = "hhX";
pub const __INT_FAST8_TYPE__ = i8;
pub const __INT_FAST8_MAX__ = @as(c_int, 127);
pub const __INT_FAST8_WIDTH__ = @as(c_int, 8);
pub const INT_FAST8_FMTd__ = "hhd";
pub const INT_FAST8_FMTi__ = "hhi";
pub const __UINT_FAST8_TYPE__ = u8;
pub const __UINT_FAST8_MAX__ = @as(c_int, 255);
pub const UINT_FAST8_FMTo__ = "hho";
pub const UINT_FAST8_FMTu__ = "hhu";
pub const UINT_FAST8_FMTx__ = "hhx";
pub const UINT_FAST8_FMTX__ = "hhX";
pub const __INT_LEAST16_TYPE__ = c_short;
pub const __INT_LEAST16_MAX__ = @as(c_int, 32767);
pub const __INT_LEAST16_WIDTH__ = @as(c_int, 16);
pub const INT_LEAST16_FMTd__ = "hd";
pub const INT_LEAST16_FMTi__ = "hi";
pub const __UINT_LEAST16_TYPE__ = c_ushort;
pub const __UINT_LEAST16_MAX__ = __helpers.promoteIntLiteral(c_int, 65535, .decimal);
pub const UINT_LEAST16_FMTo__ = "ho";
pub const UINT_LEAST16_FMTu__ = "hu";
pub const UINT_LEAST16_FMTx__ = "hx";
pub const UINT_LEAST16_FMTX__ = "hX";
pub const __INT_FAST16_TYPE__ = c_short;
pub const __INT_FAST16_MAX__ = @as(c_int, 32767);
pub const __INT_FAST16_WIDTH__ = @as(c_int, 16);
pub const INT_FAST16_FMTd__ = "hd";
pub const INT_FAST16_FMTi__ = "hi";
pub const __UINT_FAST16_TYPE__ = c_ushort;
pub const __UINT_FAST16_MAX__ = __helpers.promoteIntLiteral(c_int, 65535, .decimal);
pub const UINT_FAST16_FMTo__ = "ho";
pub const UINT_FAST16_FMTu__ = "hu";
pub const UINT_FAST16_FMTx__ = "hx";
pub const UINT_FAST16_FMTX__ = "hX";
pub const __INT_LEAST32_TYPE__ = c_int;
pub const __INT_LEAST32_MAX__ = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __INT_LEAST32_WIDTH__ = @as(c_int, 32);
pub const INT_LEAST32_FMTd__ = "d";
pub const INT_LEAST32_FMTi__ = "i";
pub const __UINT_LEAST32_TYPE__ = c_uint;
pub const __UINT_LEAST32_MAX__ = __helpers.promoteIntLiteral(c_uint, 4294967295, .decimal);
pub const UINT_LEAST32_FMTo__ = "o";
pub const UINT_LEAST32_FMTu__ = "u";
pub const UINT_LEAST32_FMTx__ = "x";
pub const UINT_LEAST32_FMTX__ = "X";
pub const __INT_FAST32_TYPE__ = c_int;
pub const __INT_FAST32_MAX__ = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __INT_FAST32_WIDTH__ = @as(c_int, 32);
pub const INT_FAST32_FMTd__ = "d";
pub const INT_FAST32_FMTi__ = "i";
pub const __UINT_FAST32_TYPE__ = c_uint;
pub const __UINT_FAST32_MAX__ = __helpers.promoteIntLiteral(c_uint, 4294967295, .decimal);
pub const UINT_FAST32_FMTo__ = "o";
pub const UINT_FAST32_FMTu__ = "u";
pub const UINT_FAST32_FMTx__ = "x";
pub const UINT_FAST32_FMTX__ = "X";
pub const __INT_LEAST64_TYPE__ = c_longlong;
pub const __INT_LEAST64_MAX__ = @as(c_longlong, 9223372036854775807);
pub const __INT_LEAST64_WIDTH__ = @as(c_int, 64);
pub const INT_LEAST64_FMTd__ = "lld";
pub const INT_LEAST64_FMTi__ = "lli";
pub const __UINT_LEAST64_TYPE__ = c_ulonglong;
pub const __UINT_LEAST64_MAX__ = @as(c_ulonglong, 18446744073709551615);
pub const UINT_LEAST64_FMTo__ = "llo";
pub const UINT_LEAST64_FMTu__ = "llu";
pub const UINT_LEAST64_FMTx__ = "llx";
pub const UINT_LEAST64_FMTX__ = "llX";
pub const __INT_FAST64_TYPE__ = c_longlong;
pub const __INT_FAST64_MAX__ = @as(c_longlong, 9223372036854775807);
pub const __INT_FAST64_WIDTH__ = @as(c_int, 64);
pub const INT_FAST64_FMTd__ = "lld";
pub const INT_FAST64_FMTi__ = "lli";
pub const __UINT_FAST64_TYPE__ = c_ulonglong;
pub const __UINT_FAST64_MAX__ = @as(c_ulonglong, 18446744073709551615);
pub const UINT_FAST64_FMTo__ = "llo";
pub const UINT_FAST64_FMTu__ = "llu";
pub const UINT_FAST64_FMTx__ = "llx";
pub const UINT_FAST64_FMTX__ = "llX";
pub const __FLT16_DENORM_MIN__ = @as(f16, 5.9604644775390625e-8);
pub const __FLT16_HAS_DENORM__ = "";
pub const __FLT16_DIG__ = @as(c_int, 3);
pub const __FLT16_DECIMAL_DIG__ = @as(c_int, 5);
pub const __FLT16_EPSILON__ = @as(f16, 9.765625e-4);
pub const __FLT16_HAS_INFINITY__ = "";
pub const __FLT16_HAS_QUIET_NAN__ = "";
pub const __FLT16_MANT_DIG__ = @as(c_int, 11);
pub const __FLT16_MAX_10_EXP__ = @as(c_int, 4);
pub const __FLT16_MAX_EXP__ = @as(c_int, 16);
pub const __FLT16_MAX__ = @as(f16, 6.5504e+4);
pub const __FLT16_MIN_10_EXP__ = -@as(c_int, 4);
pub const __FLT16_MIN_EXP__ = -@as(c_int, 13);
pub const __FLT16_MIN__ = @as(f16, 6.103515625e-5);
pub const __FLT_DENORM_MIN__ = @as(f32, 1.40129846e-45);
pub const __FLT_HAS_DENORM__ = "";
pub const __FLT_DIG__ = @as(c_int, 6);
pub const __FLT_DECIMAL_DIG__ = @as(c_int, 9);
pub const __FLT_EPSILON__ = @as(f32, 1.19209290e-7);
pub const __FLT_HAS_INFINITY__ = "";
pub const __FLT_HAS_QUIET_NAN__ = "";
pub const __FLT_MANT_DIG__ = @as(c_int, 24);
pub const __FLT_MAX_10_EXP__ = @as(c_int, 38);
pub const __FLT_MAX_EXP__ = @as(c_int, 128);
pub const __FLT_MAX__ = @as(f32, 3.40282347e+38);
pub const __FLT_MIN_10_EXP__ = -@as(c_int, 37);
pub const __FLT_MIN_EXP__ = -@as(c_int, 125);
pub const __FLT_MIN__ = @as(f32, 1.17549435e-38);
pub const __DBL_DENORM_MIN__ = @as(f64, 4.9406564584124654e-324);
pub const __DBL_HAS_DENORM__ = "";
pub const __DBL_DIG__ = @as(c_int, 15);
pub const __DBL_DECIMAL_DIG__ = @as(c_int, 17);
pub const __DBL_EPSILON__ = @as(f64, 2.2204460492503131e-16);
pub const __DBL_HAS_INFINITY__ = "";
pub const __DBL_HAS_QUIET_NAN__ = "";
pub const __DBL_MANT_DIG__ = @as(c_int, 53);
pub const __DBL_MAX_10_EXP__ = @as(c_int, 308);
pub const __DBL_MAX_EXP__ = @as(c_int, 1024);
pub const __DBL_MAX__ = @as(f64, 1.7976931348623157e+308);
pub const __DBL_MIN_10_EXP__ = -@as(c_int, 307);
pub const __DBL_MIN_EXP__ = -@as(c_int, 1021);
pub const __DBL_MIN__ = @as(f64, 2.2250738585072014e-308);
pub const __LDBL_DENORM_MIN__ = @as(c_longdouble, 3.64519953188247460253e-4951);
pub const __LDBL_HAS_DENORM__ = "";
pub const __LDBL_DIG__ = @as(c_int, 18);
pub const __LDBL_DECIMAL_DIG__ = @as(c_int, 21);
pub const __LDBL_EPSILON__ = @as(c_longdouble, 1.08420217248550443401e-19);
pub const __LDBL_HAS_INFINITY__ = "";
pub const __LDBL_HAS_QUIET_NAN__ = "";
pub const __LDBL_MANT_DIG__ = @as(c_int, 64);
pub const __LDBL_MAX_10_EXP__ = @as(c_int, 4932);
pub const __LDBL_MAX_EXP__ = @as(c_int, 16384);
pub const __LDBL_MAX__ = @as(c_longdouble, 1.18973149535723176502e+4932);
pub const __LDBL_MIN_10_EXP__ = -@as(c_int, 4931);
pub const __LDBL_MIN_EXP__ = -@as(c_int, 16381);
pub const __LDBL_MIN__ = @as(c_longdouble, 3.36210314311209350626e-4932);
pub const __FLT_EVAL_METHOD__ = @as(c_int, 0);
pub const __FLT_RADIX__ = @as(c_int, 2);
pub const __DECIMAL_DIG__ = __LDBL_DECIMAL_DIG__;
pub const __pic__ = @as(c_int, 2);
pub const __PIC__ = @as(c_int, 2);
pub const __MSVCRT_VERSION__ = @as(c_int, 0xE00);
pub const _WIN32_WINNT = @as(c_int, 0x0a00);
pub const __CRT__NO_INLINE = @as(c_int, 1);
pub const QUICKJS_H = "";
pub const @"bool" = bool;
pub const @"true" = @as(c_int, 1);
pub const @"false" = @as(c_int, 0);
pub const __bool_true_false_are_defined = @as(c_int, 1);
pub const _INC_STDIO = "";
pub const _STDIO_CONFIG_DEFINED = "";
pub const _INC_CORECRT = "";
pub const _INC__MINGW_H = "";
pub const _INC_CRTDEFS_MACRO = "";
pub const __MINGW64_PASTE2 = @compileError("unable to translate C expr: unexpected token '##'");
// tools\zig\lib\libc\include\any-windows-any\_mingw_mac.h:10:9
pub inline fn __MINGW64_PASTE(x: anytype, y: anytype) @TypeOf(__MINGW64_PASTE2(x, y)) {
    _ = &x;
    _ = &y;
    return __MINGW64_PASTE2(x, y);
}
pub const __STRINGIFY = @compileError("unable to translate C expr: unexpected token ''");
// tools\zig\lib\libc\include\any-windows-any\_mingw_mac.h:13:9
pub inline fn __MINGW64_STRINGIFY(x: anytype) @TypeOf(__STRINGIFY(x)) {
    _ = &x;
    return __STRINGIFY(x);
}
pub const __MINGW64_VERSION_MAJOR = @as(c_int, 15);
pub const __MINGW64_VERSION_MINOR = @as(c_int, 0);
pub const __MINGW64_VERSION_BUGFIX = @as(c_int, 0);
pub const __MINGW64_VERSION_RC = @as(c_int, 0);
pub const __MINGW64_VERSION_STR = __MINGW64_STRINGIFY(__MINGW64_VERSION_MAJOR) ++ "." ++ __MINGW64_STRINGIFY(__MINGW64_VERSION_MINOR) ++ "." ++ __MINGW64_STRINGIFY(__MINGW64_VERSION_BUGFIX);
pub const __MINGW64_VERSION_STATE = "alpha";
pub const __MINGW32_MAJOR_VERSION = @as(c_int, 3);
pub const __MINGW32_MINOR_VERSION = @as(c_int, 11);
pub const _M_AMD64 = @as(c_int, 100);
pub const _M_X64 = @as(c_int, 100);
pub const __MINGW_USE_UNDERSCORE_PREFIX = @as(c_int, 0);
pub const __MINGW_IMP_SYMBOL = @compileError("unable to translate macro: undefined identifier `__imp_`");
// tools\zig\lib\libc\include\any-windows-any\_mingw_mac.h:129:11
pub const __MINGW_IMP_LSYMBOL = @compileError("unable to translate macro: undefined identifier `__imp_`");
// tools\zig\lib\libc\include\any-windows-any\_mingw_mac.h:130:11
pub inline fn __MINGW_USYMBOL(sym: anytype) @TypeOf(sym) {
    _ = &sym;
    return sym;
}
pub const __MINGW_LSYMBOL = @compileError("unable to translate macro: undefined identifier `_`");
// tools\zig\lib\libc\include\any-windows-any\_mingw_mac.h:132:11
pub const __MINGW_ASM_CALL = @compileError("unable to translate C expr: unexpected token '__asm__'");
// tools\zig\lib\libc\include\any-windows-any\_mingw_mac.h:140:9
pub const __MINGW_ASM_CRT_CALL = @compileError("unable to translate C expr: unexpected token '__asm__'");
// tools\zig\lib\libc\include\any-windows-any\_mingw_mac.h:141:9
pub const __MINGW_EXTENSION = @compileError("unable to translate C expr: unexpected token '__extension__'");
// tools\zig\lib\libc\include\any-windows-any\_mingw_mac.h:173:13
pub const __C89_NAMELESS = __MINGW_EXTENSION;
pub const __C89_NAMELESSSTRUCTNAME = "";
pub const __C89_NAMELESSSTRUCTNAME1 = "";
pub const __C89_NAMELESSSTRUCTNAME2 = "";
pub const __C89_NAMELESSSTRUCTNAME3 = "";
pub const __C89_NAMELESSSTRUCTNAME4 = "";
pub const __C89_NAMELESSSTRUCTNAME5 = "";
pub const __C89_NAMELESSUNIONNAME = "";
pub const __C89_NAMELESSUNIONNAME1 = "";
pub const __C89_NAMELESSUNIONNAME2 = "";
pub const __C89_NAMELESSUNIONNAME3 = "";
pub const __C89_NAMELESSUNIONNAME4 = "";
pub const __C89_NAMELESSUNIONNAME5 = "";
pub const __C89_NAMELESSUNIONNAME6 = "";
pub const __C89_NAMELESSUNIONNAME7 = "";
pub const __C89_NAMELESSUNIONNAME8 = "";
pub const __GNU_EXTENSION = __MINGW_EXTENSION;
pub const __MINGW_HAVE_ANSI_C99_PRINTF = @as(c_int, 1);
pub const __MINGW_HAVE_WIDE_C99_PRINTF = @as(c_int, 1);
pub const __MINGW_HAVE_ANSI_C99_SCANF = @as(c_int, 1);
pub const __MINGW_HAVE_WIDE_C99_SCANF = @as(c_int, 1);
pub const __MINGW_POISON_NAME = @compileError("unable to translate macro: undefined identifier `_layout_has_not_been_verified_and_its_declaration_is_most_likely_incorrect`");
// tools\zig\lib\libc\include\any-windows-any\_mingw_mac.h:213:11
pub const __MSABI_LONG = __helpers.L_SUFFIX;
pub const __MINGW_GCC_VERSION = ((__GNUC__ * @as(c_int, 10000)) + (__GNUC_MINOR__ * @as(c_int, 100))) + __GNUC_PATCHLEVEL__;
pub inline fn __MINGW_GNUC_PREREQ(major: anytype, minor: anytype) @TypeOf((__GNUC__ > major) or ((__GNUC__ == major) and (__GNUC_MINOR__ >= minor))) {
    _ = &major;
    _ = &minor;
    return (__GNUC__ > major) or ((__GNUC__ == major) and (__GNUC_MINOR__ >= minor));
}
pub inline fn __MINGW_MSC_PREREQ(major: anytype, minor: anytype) @TypeOf(@as(c_int, 0)) {
    _ = &major;
    _ = &minor;
    return @as(c_int, 0);
}
pub inline fn __MINGW_ATTRIB_DEPRECATED_STR(X: anytype) void {
    _ = &X;
    return;
}
pub const __MINGW_SEC_WARN_STR = "This function or variable may be unsafe, use _CRT_SECURE_NO_WARNINGS to disable deprecation";
pub const __MINGW_MSVC2005_DEPREC_STR = "This POSIX function is deprecated beginning in Visual C++ 2005, use _CRT_NONSTDC_NO_DEPRECATE to disable deprecation";
pub const __MINGW_ATTRIB_DEPRECATED_MSVC2005 = __MINGW_ATTRIB_DEPRECATED_STR(__MINGW_MSVC2005_DEPREC_STR);
pub const __MINGW_ATTRIB_DEPRECATED_SEC_WARN = __MINGW_ATTRIB_DEPRECATED_STR(__MINGW_SEC_WARN_STR);
pub const __MINGW_MS_PRINTF = @compileError("unable to translate macro: undefined identifier `__format__`");
// tools\zig\lib\libc\include\any-windows-any\_mingw_mac.h:293:9
pub const __MINGW_MS_SCANF = @compileError("unable to translate macro: undefined identifier `__format__`");
// tools\zig\lib\libc\include\any-windows-any\_mingw_mac.h:296:9
pub const __MINGW_GNU_PRINTF = @compileError("unable to translate macro: undefined identifier `__format__`");
// tools\zig\lib\libc\include\any-windows-any\_mingw_mac.h:299:9
pub const __MINGW_GNU_SCANF = @compileError("unable to translate macro: undefined identifier `__format__`");
// tools\zig\lib\libc\include\any-windows-any\_mingw_mac.h:302:9
pub const __mingw_ovr = @compileError("unable to translate macro: undefined identifier `__unused__`");
// tools\zig\lib\libc\include\any-windows-any\_mingw_mac.h:311:11
pub const __mingw_attribute_artificial = @compileError("unable to translate macro: undefined identifier `__artificial__`");
// tools\zig\lib\libc\include\any-windows-any\_mingw_mac.h:318:11
pub const __MINGW_SELECTANY = @compileError("unable to translate macro: undefined identifier `__selectany__`");
// tools\zig\lib\libc\include\any-windows-any\_mingw_mac.h:324:9
pub const __MINGW_FORTIFY_LEVEL = @as(c_int, 0);
pub const __mingw_bos_ovr = __mingw_ovr;
pub const __MINGW_FORTIFY_VA_ARG = @as(c_int, 0);
pub const _INC_MINGW_SECAPI = "";
pub const _CRT_SECURE_CPP_OVERLOAD_SECURE_NAMES = @as(c_int, 0);
pub const _CRT_SECURE_CPP_OVERLOAD_SECURE_NAMES_MEMORY = @as(c_int, 0);
pub const _CRT_SECURE_CPP_OVERLOAD_STANDARD_NAMES = @as(c_int, 0);
pub const _CRT_SECURE_CPP_OVERLOAD_STANDARD_NAMES_COUNT = @as(c_int, 0);
pub const _CRT_SECURE_CPP_OVERLOAD_STANDARD_NAMES_MEMORY = @as(c_int, 0);
pub const __MINGW_CRT_NAME_CONCAT2 = @compileError("unable to translate macro: undefined identifier `_s`");
// tools\zig\lib\libc\include\any-windows-any\_mingw_secapi.h:41:9
pub const __CRT_SECURE_CPP_OVERLOAD_STANDARD_NAMES_MEMORY_0_3_ = @compileError("unable to translate C expr: unexpected token '__cdecl'");
// tools\zig\lib\libc\include\any-windows-any\_mingw_secapi.h:69:9
pub const __LONG32 = c_long;
pub const __MINGW_IMPORT = @compileError("unable to translate macro: undefined identifier `__dllimport__`");
// tools\zig\lib\libc\include\any-windows-any\_mingw.h:44:12
pub const __USE_CRTIMP = @as(c_int, 1);
pub const _CRTIMP = @compileError("unable to translate macro: undefined identifier `__dllimport__`");
// tools\zig\lib\libc\include\any-windows-any\_mingw.h:52:15
pub const __DECLSPEC_SUPPORTED = "";
pub const USE___UUIDOF = @as(c_int, 0);
pub const _inline = @compileError("unable to translate C expr: unexpected token '__inline'");
// tools\zig\lib\libc\include\any-windows-any\_mingw.h:74:9
pub const __CRT_INLINE = @compileError("unable to translate macro: undefined identifier `__gnu_inline__`");
// tools\zig\lib\libc\include\any-windows-any\_mingw.h:83:11
pub const __MINGW_INTRIN_INLINE = @compileError("unable to translate macro: undefined identifier `__always_inline__`");
// tools\zig\lib\libc\include\any-windows-any\_mingw.h:90:9
pub const __MINGW_CXX11_CONSTEXPR = "";
pub const __MINGW_CXX14_CONSTEXPR = "";
pub const __UNUSED_PARAM = @compileError("unable to translate macro: undefined identifier `__unused__`");
// tools\zig\lib\libc\include\any-windows-any\_mingw.h:118:11
pub const __restrict_arr = @compileError("unable to translate C expr: unexpected token '__restrict'");
// tools\zig\lib\libc\include\any-windows-any\_mingw.h:133:10
pub const __MINGW_ATTRIB_NORETURN = @compileError("unable to translate macro: undefined identifier `__noreturn__`");
// tools\zig\lib\libc\include\any-windows-any\_mingw.h:149:9
pub const __MINGW_ATTRIB_CONST = @compileError("unable to translate C expr: unexpected token '__attribute__'");
// tools\zig\lib\libc\include\any-windows-any\_mingw.h:150:9
pub const __MINGW_ATTRIB_MALLOC = @compileError("unable to translate macro: undefined identifier `__malloc__`");
// tools\zig\lib\libc\include\any-windows-any\_mingw.h:160:9
pub const __MINGW_ATTRIB_PURE = @compileError("unable to translate macro: undefined identifier `__pure__`");
// tools\zig\lib\libc\include\any-windows-any\_mingw.h:161:9
pub const __MINGW_ATTRIB_NONNULL = @compileError("unable to translate macro: undefined identifier `__nonnull__`");
// tools\zig\lib\libc\include\any-windows-any\_mingw.h:174:9
pub const __MINGW_ATTRIB_UNUSED = @compileError("unable to translate macro: undefined identifier `__unused__`");
// tools\zig\lib\libc\include\any-windows-any\_mingw.h:180:9
pub const __MINGW_ATTRIB_USED = @compileError("unable to translate macro: undefined identifier `__used__`");
// tools\zig\lib\libc\include\any-windows-any\_mingw.h:186:9
pub const __MINGW_ATTRIB_DEPRECATED = @compileError("unable to translate macro: undefined identifier `__deprecated__`");
// tools\zig\lib\libc\include\any-windows-any\_mingw.h:187:9
pub const __MINGW_ATTRIB_DEPRECATED_MSG = @compileError("unable to translate macro: undefined identifier `__deprecated__`");
// tools\zig\lib\libc\include\any-windows-any\_mingw.h:189:9
pub const __MINGW_NOTHROW = @compileError("unable to translate macro: undefined identifier `__nothrow__`");
// tools\zig\lib\libc\include\any-windows-any\_mingw.h:204:9
pub const __MINGW_ATTRIB_NO_OPTIMIZE = @compileError("unable to translate macro: undefined identifier `__optimize__`");
// tools\zig\lib\libc\include\any-windows-any\_mingw.h:212:9
pub const __MINGW_PRAGMA_PARAM = @compileError("unable to translate macro: undefined identifier `_Pragma`");
// tools\zig\lib\libc\include\any-windows-any\_mingw.h:218:9
pub const __MINGW_BROKEN_INTERFACE = @compileError("unable to translate macro: undefined identifier `message`");
// tools\zig\lib\libc\include\any-windows-any\_mingw.h:225:9
pub const _UCRT = "";
pub inline fn __MINGW_UCRT_ASM_CALL(func: anytype) @TypeOf(__MINGW_ASM_CALL(func)) {
    _ = &func;
    return __MINGW_ASM_CALL(func);
}
pub const _INT128_DEFINED = "";
pub const __int8 = u8;
pub const __int16 = c_short;
pub const __int32 = c_int;
pub const __int64 = c_longlong;
pub const __ptr32 = "";
pub const __ptr64 = "";
pub const __unaligned = "";
pub const __w64 = "";
pub const __forceinline = @compileError("unable to translate macro: undefined identifier `__always_inline__`");
// tools\zig\lib\libc\include\any-windows-any\_mingw.h:290:9
pub const __nothrow = "";
pub const _INC_VADEFS = "";
pub const __GNUC_VA_LIST = "";
pub const _VA_LIST_DEFINED = "";
pub inline fn _ADDRESSOF(v: anytype) @TypeOf(&v) {
    _ = &v;
    return &v;
}
pub const _crt_va_start = @compileError("unable to translate macro: undefined identifier `__builtin_va_start`");
// tools\zig\lib\libc\include\any-windows-any\vadefs.h:48:9
pub const _crt_va_arg = @compileError("unable to translate macro: undefined identifier `__builtin_va_arg`");
// tools\zig\lib\libc\include\any-windows-any\vadefs.h:49:9
pub const _crt_va_end = @compileError("unable to translate macro: undefined identifier `__builtin_va_end`");
// tools\zig\lib\libc\include\any-windows-any\vadefs.h:50:9
pub const _crt_va_copy = @compileError("unable to translate macro: undefined identifier `__builtin_va_copy`");
// tools\zig\lib\libc\include\any-windows-any\vadefs.h:51:9
pub const __CRT_STRINGIZE = @compileError("unable to translate C expr: unexpected token ''");
// tools\zig\lib\libc\include\any-windows-any\_mingw.h:309:9
pub inline fn _CRT_STRINGIZE(_Value: anytype) @TypeOf(__CRT_STRINGIZE(_Value)) {
    _ = &_Value;
    return __CRT_STRINGIZE(_Value);
}
pub const __CRT_WIDE = @compileError("unable to translate macro: undefined identifier `L`");
// tools\zig\lib\libc\include\any-windows-any\_mingw.h:314:9
pub inline fn _CRT_WIDE(_String: anytype) @TypeOf(__CRT_WIDE(_String)) {
    _ = &_String;
    return __CRT_WIDE(_String);
}
pub const _W64 = "";
pub const _CRTIMP_NOIA64 = _CRTIMP;
pub const _CRTIMP2 = _CRTIMP;
pub const _CRTIMP_ALTERNATIVE = _CRTIMP;
pub const _CRT_ALTERNATIVE_IMPORTED = "";
pub const _MRTIMP2 = _CRTIMP;
pub const _DLL = "";
pub const _MT = "";
pub const _MCRTIMP = _CRTIMP;
pub const _CRTIMP_PURE = _CRTIMP;
pub const _PGLOBAL = "";
pub const _AGLOBAL = "";
pub const _SECURECRT_FILL_BUFFER_PATTERN = @as(c_int, 0xFD);
pub const _CRT_DEPRECATE_TEXT = @compileError("unable to translate macro: undefined identifier `deprecated`");
// tools\zig\lib\libc\include\any-windows-any\_mingw.h:373:9
pub inline fn _CRT_INSECURE_DEPRECATE_MEMORY(_Replacement: anytype) void {
    _ = &_Replacement;
    return;
}
pub inline fn _CRT_INSECURE_DEPRECATE_GLOBALS(_Replacement: anytype) void {
    _ = &_Replacement;
    return;
}
pub const _CRT_MANAGED_HEAP_DEPRECATE = "";
pub inline fn _CRT_OBSOLETE(_NewItem: anytype) void {
    _ = &_NewItem;
    return;
}
pub const _CONST_RETURN = "";
pub const UNALIGNED = "";
pub const _CRT_ALIGN = @compileError("unable to translate macro: undefined identifier `__aligned__`");
// tools\zig\lib\libc\include\any-windows-any\_mingw.h:415:9
pub const __CRTDECL = @compileError("unable to translate C expr: unexpected token '__cdecl'");
// tools\zig\lib\libc\include\any-windows-any\_mingw.h:422:9
pub const _ARGMAX = @as(c_int, 100);
pub const _TRUNCATE = __helpers.cast(usize, -@as(c_int, 1));
pub inline fn _CRT_UNUSED(x: anytype) anyopaque {
    _ = &x;
    return __helpers.cast(anyopaque, x);
}
pub const __USE_MINGW_ANSI_STDIO = @as(c_int, 0);
pub const _CRT_glob = @compileError("unable to translate macro: undefined identifier `_dowildcard`");
// tools\zig\lib\libc\include\any-windows-any\_mingw.h:479:9
pub const __ANONYMOUS_DEFINED = "";
pub const _ANONYMOUS_UNION = __MINGW_EXTENSION;
pub const _ANONYMOUS_STRUCT = __MINGW_EXTENSION;
pub inline fn _UNION_NAME(x: anytype) void {
    _ = &x;
    return;
}
pub inline fn _STRUCT_NAME(x: anytype) void {
    _ = &x;
    return;
}
pub const DUMMYUNIONNAME = "";
pub const DUMMYUNIONNAME1 = "";
pub const DUMMYUNIONNAME2 = "";
pub const DUMMYUNIONNAME3 = "";
pub const DUMMYUNIONNAME4 = "";
pub const DUMMYUNIONNAME5 = "";
pub const DUMMYUNIONNAME6 = "";
pub const DUMMYUNIONNAME7 = "";
pub const DUMMYUNIONNAME8 = "";
pub const DUMMYUNIONNAME9 = "";
pub const DUMMYSTRUCTNAME = "";
pub const DUMMYSTRUCTNAME1 = "";
pub const DUMMYSTRUCTNAME2 = "";
pub const DUMMYSTRUCTNAME3 = "";
pub const DUMMYSTRUCTNAME4 = "";
pub const DUMMYSTRUCTNAME5 = "";
pub inline fn __CRT_UUID_DECL(@"type": anytype, l: anytype, w1: anytype, w2: anytype, b1: anytype, b2: anytype, b3: anytype, b4: anytype, b5: anytype, b6: anytype, b7: anytype, b8: anytype) void {
    _ = &@"type";
    _ = &l;
    _ = &w1;
    _ = &w2;
    _ = &b1;
    _ = &b2;
    _ = &b3;
    _ = &b4;
    _ = &b5;
    _ = &b6;
    _ = &b7;
    _ = &b8;
    return;
}
pub const __MINGW_DEBUGBREAK_IMPL = @compileError("unable to translate macro: undefined identifier `__debugbreak`");
// tools\zig\lib\libc\include\any-windows-any\_mingw.h:599:9
pub const __MINGW_FASTFAIL_IMPL = @compileError("unable to translate macro: undefined identifier `__fastfail`");
// tools\zig\lib\libc\include\any-windows-any\_mingw.h:620:9
pub const __MINGW_PREFETCH_IMPL = @compileError("unable to translate macro: undefined identifier `__prefetch`");
// tools\zig\lib\libc\include\any-windows-any\_mingw.h:644:9
pub const __STDC_SECURE_LIB__ = @as(c_long, 200411);
pub const __GOT_SECURE_LIB__ = __STDC_SECURE_LIB__;
pub const _CRT_PACKING = @as(c_int, 8);
pub const _CRTNOALIAS = "";
pub const _CRTRESTRICT = "";
pub const _SIZE_T_DEFINED = "";
pub const _SSIZE_T_DEFINED = "";
pub const _RSIZE_T_DEFINED = "";
pub const _INTPTR_T_DEFINED = "";
pub const __intptr_t_defined = "";
pub const _UINTPTR_T_DEFINED = "";
pub const __uintptr_t_defined = "";
pub const _PTRDIFF_T_DEFINED = "";
pub const _PTRDIFF_T_ = "";
pub const _WCHAR_T_DEFINED = "";
pub const _WCTYPE_T_DEFINED = "";
pub const _WINT_T = "";
pub const _ERRCODE_DEFINED = "";
pub const _TIME32_T_DEFINED = "";
pub const _TIME64_T_DEFINED = "";
pub const _TIME_T_DEFINED = "";
pub const _CRT_SECURE_CPP_NOTHROW = @compileError("unable to translate macro: undefined identifier `throw`");
// tools\zig\lib\libc\include\any-windows-any\corecrt.h:143:9
pub inline fn __DEFINE_CPP_OVERLOAD_SECURE_FUNC_0_0(__ret: anytype, __func: anytype, __dsttype: anytype, __dst: anytype) void {
    _ = &__ret;
    _ = &__func;
    _ = &__dsttype;
    _ = &__dst;
    return;
}
pub inline fn __DEFINE_CPP_OVERLOAD_SECURE_FUNC_0_1(__ret: anytype, __func: anytype, __dsttype: anytype, __dst: anytype, __type1: anytype, __arg1: anytype) void {
    _ = &__ret;
    _ = &__func;
    _ = &__dsttype;
    _ = &__dst;
    _ = &__type1;
    _ = &__arg1;
    return;
}
pub inline fn __DEFINE_CPP_OVERLOAD_SECURE_FUNC_0_2(__ret: anytype, __func: anytype, __dsttype: anytype, __dst: anytype, __type1: anytype, __arg1: anytype, __type2: anytype, __arg2: anytype) void {
    _ = &__ret;
    _ = &__func;
    _ = &__dsttype;
    _ = &__dst;
    _ = &__type1;
    _ = &__arg1;
    _ = &__type2;
    _ = &__arg2;
    return;
}
pub inline fn __DEFINE_CPP_OVERLOAD_SECURE_FUNC_0_3(__ret: anytype, __func: anytype, __dsttype: anytype, __dst: anytype, __type1: anytype, __arg1: anytype, __type2: anytype, __arg2: anytype, __type3: anytype, __arg3: anytype) void {
    _ = &__ret;
    _ = &__func;
    _ = &__dsttype;
    _ = &__dst;
    _ = &__type1;
    _ = &__arg1;
    _ = &__type2;
    _ = &__arg2;
    _ = &__type3;
    _ = &__arg3;
    return;
}
pub inline fn __DEFINE_CPP_OVERLOAD_SECURE_FUNC_0_4(__ret: anytype, __func: anytype, __dsttype: anytype, __dst: anytype, __type1: anytype, __arg1: anytype, __type2: anytype, __arg2: anytype, __type3: anytype, __arg3: anytype, __type4: anytype, __arg4: anytype) void {
    _ = &__ret;
    _ = &__func;
    _ = &__dsttype;
    _ = &__dst;
    _ = &__type1;
    _ = &__arg1;
    _ = &__type2;
    _ = &__arg2;
    _ = &__type3;
    _ = &__arg3;
    _ = &__type4;
    _ = &__arg4;
    return;
}
pub inline fn __DEFINE_CPP_OVERLOAD_SECURE_FUNC_1_1(__ret: anytype, __func: anytype, __type0: anytype, __arg0: anytype, __dsttype: anytype, __dst: anytype, __type1: anytype, __arg1: anytype) void {
    _ = &__ret;
    _ = &__func;
    _ = &__type0;
    _ = &__arg0;
    _ = &__dsttype;
    _ = &__dst;
    _ = &__type1;
    _ = &__arg1;
    return;
}
pub inline fn __DEFINE_CPP_OVERLOAD_SECURE_FUNC_1_2(__ret: anytype, __func: anytype, __type0: anytype, __arg0: anytype, __dsttype: anytype, __dst: anytype, __type1: anytype, __arg1: anytype, __type2: anytype, __arg2: anytype) void {
    _ = &__ret;
    _ = &__func;
    _ = &__type0;
    _ = &__arg0;
    _ = &__dsttype;
    _ = &__dst;
    _ = &__type1;
    _ = &__arg1;
    _ = &__type2;
    _ = &__arg2;
    return;
}
pub inline fn __DEFINE_CPP_OVERLOAD_SECURE_FUNC_1_3(__ret: anytype, __func: anytype, __type0: anytype, __arg0: anytype, __dsttype: anytype, __dst: anytype, __type1: anytype, __arg1: anytype, __type2: anytype, __arg2: anytype, __type3: anytype, __arg3: anytype) void {
    _ = &__ret;
    _ = &__func;
    _ = &__type0;
    _ = &__arg0;
    _ = &__dsttype;
    _ = &__dst;
    _ = &__type1;
    _ = &__arg1;
    _ = &__type2;
    _ = &__arg2;
    _ = &__type3;
    _ = &__arg3;
    return;
}
pub inline fn __DEFINE_CPP_OVERLOAD_SECURE_FUNC_2_0(__ret: anytype, __func: anytype, __type1: anytype, __arg1: anytype, __type2: anytype, __arg2: anytype, __dsttype: anytype, __dst: anytype) void {
    _ = &__ret;
    _ = &__func;
    _ = &__type1;
    _ = &__arg1;
    _ = &__type2;
    _ = &__arg2;
    _ = &__dsttype;
    _ = &__dst;
    return;
}
pub inline fn __DEFINE_CPP_OVERLOAD_SECURE_FUNC_0_1_ARGLIST(__ret: anytype, __func: anytype, __vfunc: anytype, __dsttype: anytype, __dst: anytype, __type1: anytype, __arg1: anytype) void {
    _ = &__ret;
    _ = &__func;
    _ = &__vfunc;
    _ = &__dsttype;
    _ = &__dst;
    _ = &__type1;
    _ = &__arg1;
    return;
}
pub inline fn __DEFINE_CPP_OVERLOAD_SECURE_FUNC_0_2_ARGLIST(__ret: anytype, __func: anytype, __vfunc: anytype, __dsttype: anytype, __dst: anytype, __type1: anytype, __arg1: anytype, __type2: anytype, __arg2: anytype) void {
    _ = &__ret;
    _ = &__func;
    _ = &__vfunc;
    _ = &__dsttype;
    _ = &__dst;
    _ = &__type1;
    _ = &__arg1;
    _ = &__type2;
    _ = &__arg2;
    return;
}
pub inline fn __DEFINE_CPP_OVERLOAD_SECURE_FUNC_SPLITPATH(__ret: anytype, __func: anytype, __dsttype: anytype, __src: anytype) void {
    _ = &__ret;
    _ = &__func;
    _ = &__dsttype;
    _ = &__src;
    return;
}
pub const __DEFINE_CPP_OVERLOAD_STANDARD_FUNC_0_0 = @compileError("unable to translate macro: undefined identifier `__func_name`");
// tools\zig\lib\libc\include\any-windows-any\corecrt.h:284:9
pub const __DEFINE_CPP_OVERLOAD_STANDARD_FUNC_0_1 = @compileError("unable to translate macro: undefined identifier `__func_name`");
// tools\zig\lib\libc\include\any-windows-any\corecrt.h:286:9
pub const __DEFINE_CPP_OVERLOAD_STANDARD_FUNC_0_2 = @compileError("unable to translate macro: undefined identifier `__func_name`");
// tools\zig\lib\libc\include\any-windows-any\corecrt.h:288:9
pub const __DEFINE_CPP_OVERLOAD_STANDARD_FUNC_0_3 = @compileError("unable to translate macro: undefined identifier `__func_name`");
// tools\zig\lib\libc\include\any-windows-any\corecrt.h:290:9
pub const __DEFINE_CPP_OVERLOAD_STANDARD_FUNC_0_4 = @compileError("unable to translate macro: undefined identifier `__func_name`");
// tools\zig\lib\libc\include\any-windows-any\corecrt.h:292:9
pub inline fn __DEFINE_CPP_OVERLOAD_STANDARD_FUNC_0_0_EX(__ret_type: anytype, __ret_policy: anytype, __decl_spec: anytype, __name: anytype, __sec_name: anytype, __dst_attr: anytype, __dst_type: anytype, __dst: anytype) void {
    _ = &__ret_type;
    _ = &__ret_policy;
    _ = &__decl_spec;
    _ = &__name;
    _ = &__sec_name;
    _ = &__dst_attr;
    _ = &__dst_type;
    _ = &__dst;
    return;
}
pub inline fn __DEFINE_CPP_OVERLOAD_STANDARD_FUNC_0_1_EX(__ret_type: anytype, __ret_policy: anytype, __decl_spec: anytype, __name: anytype, __sec_name: anytype, __dst_attr: anytype, __dst_type: anytype, __dst: anytype, __arg1_type: anytype, __arg1: anytype) void {
    _ = &__ret_type;
    _ = &__ret_policy;
    _ = &__decl_spec;
    _ = &__name;
    _ = &__sec_name;
    _ = &__dst_attr;
    _ = &__dst_type;
    _ = &__dst;
    _ = &__arg1_type;
    _ = &__arg1;
    return;
}
pub inline fn __DEFINE_CPP_OVERLOAD_STANDARD_FUNC_0_2_EX(__ret_type: anytype, __ret_policy: anytype, __decl_spec: anytype, __name: anytype, __sec_name: anytype, __dst_attr: anytype, __dst_type: anytype, __dst: anytype, __arg1_type: anytype, __arg1: anytype, __arg2_type: anytype, __arg2: anytype) void {
    _ = &__ret_type;
    _ = &__ret_policy;
    _ = &__decl_spec;
    _ = &__name;
    _ = &__sec_name;
    _ = &__dst_attr;
    _ = &__dst_type;
    _ = &__dst;
    _ = &__arg1_type;
    _ = &__arg1;
    _ = &__arg2_type;
    _ = &__arg2;
    return;
}
pub inline fn __DEFINE_CPP_OVERLOAD_STANDARD_FUNC_0_3_EX(__ret_type: anytype, __ret_policy: anytype, __decl_spec: anytype, __name: anytype, __sec_name: anytype, __dst_attr: anytype, __dst_type: anytype, __dst: anytype, __arg1_type: anytype, __arg1: anytype, __arg2_type: anytype, __arg2: anytype, __arg3_type: anytype, __arg3: anytype) void {
    _ = &__ret_type;
    _ = &__ret_policy;
    _ = &__decl_spec;
    _ = &__name;
    _ = &__sec_name;
    _ = &__dst_attr;
    _ = &__dst_type;
    _ = &__dst;
    _ = &__arg1_type;
    _ = &__arg1;
    _ = &__arg2_type;
    _ = &__arg2;
    _ = &__arg3_type;
    _ = &__arg3;
    return;
}
pub inline fn __DEFINE_CPP_OVERLOAD_STANDARD_FUNC_0_4_EX(__ret_type: anytype, __ret_policy: anytype, __decl_spec: anytype, __name: anytype, __sec_name: anytype, __dst_attr: anytype, __dst_type: anytype, __dst: anytype, __arg1_type: anytype, __arg1: anytype, __arg2_type: anytype, __arg2: anytype, __arg3_type: anytype, __arg3: anytype, __arg4_type: anytype, __arg4: anytype) void {
    _ = &__ret_type;
    _ = &__ret_policy;
    _ = &__decl_spec;
    _ = &__name;
    _ = &__sec_name;
    _ = &__dst_attr;
    _ = &__dst_type;
    _ = &__dst;
    _ = &__arg1_type;
    _ = &__arg1;
    _ = &__arg2_type;
    _ = &__arg2;
    _ = &__arg3_type;
    _ = &__arg3;
    _ = &__arg4_type;
    _ = &__arg4;
    return;
}
pub const _TAGLC_ID_DEFINED = "";
pub inline fn __crt_typefix(ctype: anytype) void {
    _ = &ctype;
    return;
}
pub const _CRT_USE_WINAPI_FAMILY_DESKTOP_APP = "";
pub const _CRT_INTERNAL_PRINTF_LEGACY_VSPRINTF_NULL_TERMINATION = @as(c_ulonglong, 0x0001);
pub const _CRT_INTERNAL_PRINTF_STANDARD_SNPRINTF_BEHAVIOR = @as(c_ulonglong, 0x0002);
pub const _CRT_INTERNAL_PRINTF_LEGACY_WIDE_SPECIFIERS = @as(c_ulonglong, 0x0004);
pub const _CRT_INTERNAL_PRINTF_LEGACY_MSVCRT_COMPATIBILITY = @as(c_ulonglong, 0x0008);
pub const _CRT_INTERNAL_PRINTF_LEGACY_THREE_DIGIT_EXPONENTS = @as(c_ulonglong, 0x0010);
pub const _CRT_INTERNAL_PRINTF_STANDARD_ROUNDING = @as(c_ulonglong, 0x0020);
pub const _CRT_INTERNAL_SCANF_SECURECRT = @as(c_ulonglong, 0x0001);
pub const _CRT_INTERNAL_SCANF_LEGACY_WIDE_SPECIFIERS = @as(c_ulonglong, 0x0002);
pub const _CRT_INTERNAL_SCANF_LEGACY_MSVCRT_COMPATIBILITY = @as(c_ulonglong, 0x0004);
pub const _CRT_INTERNAL_LOCAL_PRINTF_OPTIONS = __local_stdio_printf_options().*;
pub const _CRT_INTERNAL_LOCAL_SCANF_OPTIONS = __local_stdio_scanf_options().*;
pub const BUFSIZ = @as(c_int, 512);
pub const _NFILE = _NSTREAM_;
pub const _NSTREAM_ = @as(c_int, 512);
pub const _IOB_ENTRIES = @as(c_int, 20);
pub const EOF = -@as(c_int, 1);
pub const _FILE_DEFINED = "";
pub const _P_tmpdir = "\\";
pub const _wP_tmpdir = "\\";
pub const L_tmpnam = @as(c_int, 260);
pub const SEEK_CUR = @as(c_int, 1);
pub const SEEK_END = @as(c_int, 2);
pub const SEEK_SET = @as(c_int, 0);
pub const STDIN_FILENO = @as(c_int, 0);
pub const STDOUT_FILENO = @as(c_int, 1);
pub const STDERR_FILENO = @as(c_int, 2);
pub const FILENAME_MAX = @as(c_int, 260);
pub const FOPEN_MAX = @as(c_int, 20);
pub const _SYS_OPEN = @as(c_int, 20);
pub const TMP_MAX = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const NULL = __helpers.cast(?*anyopaque, @as(c_int, 0));
pub const _OFF_T_DEFINED = "";
pub const _OFF_T_ = "";
pub const _OFF64_T_DEFINED = "";
pub const _FILE_OFFSET_BITS_SET_OFFT = "";
pub const _iob = __iob_func();
pub const _FPOS_T_DEFINED = "";
pub inline fn _FPOSOFF(fp: anytype) c_long {
    _ = &fp;
    return __helpers.cast(c_long, fp);
}
pub const _STDSTREAM_DEFINED = "";
pub const stdin = __acrt_iob_func(@as(c_int, 0));
pub const stdout = __acrt_iob_func(@as(c_int, 1));
pub const stderr = __acrt_iob_func(@as(c_int, 2));
pub const _IOFBF = @as(c_int, 0x0000);
pub const _IOLBF = @as(c_int, 0x0040);
pub const _IONBF = @as(c_int, 0x0004);
pub const __MINGW_PRINTF_FORMAT = @compileError("unable to translate macro: undefined identifier `__gnu_printf__`");
// tools\zig\lib\libc\include\any-windows-any\stdio.h:280:9
pub const __MINGW_SCANF_FORMAT = @compileError("unable to translate macro: undefined identifier `__gnu_scanf__`");
// tools\zig\lib\libc\include\any-windows-any\stdio.h:281:9
pub const _CRT_PERROR_DEFINED = "";
pub const popen = _popen;
pub const pclose = _pclose;
pub const _CRT_DIRECTORY_DEFINED = "";
pub const _WSTDIO_DEFINED = "";
pub const WEOF = __helpers.cast(wint_t, __helpers.promoteIntLiteral(c_int, 0xFFFF, .hex));
pub const _INC_SWPRINTF_INL = "";
pub const _CRT_WPERROR_DEFINED = "";
pub const wpopen = _wpopen;
pub inline fn _putwc_nolock(_c: anytype, _stm: anytype) @TypeOf(_fputwc_nolock(_c, _stm)) {
    _ = &_c;
    _ = &_stm;
    return _fputwc_nolock(_c, _stm);
}
pub inline fn _getwc_nolock(_c: anytype) @TypeOf(_fgetwc_nolock(_c)) {
    _ = &_c;
    return _fgetwc_nolock(_c);
}
pub const _STDIO_DEFINED = "";
pub inline fn _getchar_nolock() @TypeOf(_getc_nolock(stdin)) {
    return _getc_nolock(stdin);
}
pub inline fn _putchar_nolock(_c: anytype) @TypeOf(_putc_nolock(_c, stdout)) {
    _ = &_c;
    return _putc_nolock(_c, stdout);
}
pub inline fn _getwchar_nolock() @TypeOf(_getwc_nolock(stdin)) {
    return _getwc_nolock(stdin);
}
pub inline fn _putwchar_nolock(_c: anytype) @TypeOf(_putwc_nolock(_c, stdout)) {
    _ = &_c;
    return _putwc_nolock(_c, stdout);
}
pub const P_tmpdir = _P_tmpdir;
pub const SYS_OPEN = _SYS_OPEN;
pub const __MINGW_MBWC_CONVERT_DEFINED = "";
pub const _WSPAWN_DEFINED = "";
pub const _P_WAIT = @as(c_int, 0);
pub const _P_NOWAIT = @as(c_int, 1);
pub const _OLD_P_OVERLAY = @as(c_int, 2);
pub const _P_NOWAITO = @as(c_int, 3);
pub const _P_DETACH = @as(c_int, 4);
pub const _P_OVERLAY = @as(c_int, 2);
pub const _WAIT_CHILD = @as(c_int, 0);
pub const _WAIT_GRANDCHILD = @as(c_int, 1);
pub const _SPAWNV_DEFINED = "";
pub const _INC_STDIO_S = "";
pub const _SECIMP = @compileError("unable to translate macro: undefined identifier `dllimport`");
// tools\zig\lib\libc\include\any-windows-any\sec_api\stdio_s.h:16:9
pub const _STDIO_S_DEFINED = "";
pub const L_tmpnam_s = L_tmpnam;
pub const TMP_MAX_S = TMP_MAX;
pub const _WSTDIO_S_DEFINED = "";
pub const __CLANG_STDINT_H = "";
pub const _STDINT_H = "";
pub const _INC_CRTDEFS = "";
pub const __need_wint_t = "";
pub const __need_wchar_t = "";
pub const __STDC_VERSION_STDDEF_H__ = @as(c_long, 202311);
pub const offsetof = @compileError("unable to translate macro: undefined identifier `__builtin_offsetof`");
// tools\zig\lib\compiler\aro\include\stddef.h:18:9
pub const INT8_MIN = -@as(c_int, 128);
pub const INT16_MIN = -__helpers.promoteIntLiteral(c_int, 32768, .decimal);
pub const INT32_MIN = -__helpers.promoteIntLiteral(c_int, 2147483647, .decimal) - @as(c_int, 1);
pub const INT64_MIN = -@as(c_longlong, 9223372036854775807) - @as(c_int, 1);
pub const INT8_MAX = @as(c_int, 127);
pub const INT16_MAX = @as(c_int, 32767);
pub const INT32_MAX = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const INT64_MAX = @as(c_longlong, 9223372036854775807);
pub const UINT8_MAX = @as(c_int, 255);
pub const UINT16_MAX = __helpers.promoteIntLiteral(c_int, 65535, .decimal);
pub const UINT32_MAX = __helpers.promoteIntLiteral(c_uint, 0xffffffff, .hex);
pub const UINT64_MAX = @as(c_ulonglong, 0xffffffffffffffff);
pub const INT_LEAST8_MIN = INT8_MIN;
pub const INT_LEAST16_MIN = INT16_MIN;
pub const INT_LEAST32_MIN = INT32_MIN;
pub const INT_LEAST64_MIN = INT64_MIN;
pub const INT_LEAST8_MAX = INT8_MAX;
pub const INT_LEAST16_MAX = INT16_MAX;
pub const INT_LEAST32_MAX = INT32_MAX;
pub const INT_LEAST64_MAX = INT64_MAX;
pub const UINT_LEAST8_MAX = UINT8_MAX;
pub const UINT_LEAST16_MAX = UINT16_MAX;
pub const UINT_LEAST32_MAX = UINT32_MAX;
pub const UINT_LEAST64_MAX = UINT64_MAX;
pub const INT_FAST8_MIN = INT8_MIN;
pub const INT_FAST16_MIN = INT16_MIN;
pub const INT_FAST32_MIN = INT32_MIN;
pub const INT_FAST64_MIN = INT64_MIN;
pub const INT_FAST8_MAX = INT8_MAX;
pub const INT_FAST16_MAX = INT16_MAX;
pub const INT_FAST32_MAX = INT32_MAX;
pub const INT_FAST64_MAX = INT64_MAX;
pub const UINT_FAST8_MAX = UINT8_MAX;
pub const UINT_FAST16_MAX = UINT16_MAX;
pub const UINT_FAST32_MAX = UINT32_MAX;
pub const UINT_FAST64_MAX = UINT64_MAX;
pub const INTPTR_MIN = INT64_MIN;
pub const INTPTR_MAX = INT64_MAX;
pub const UINTPTR_MAX = UINT64_MAX;
pub const INTMAX_MIN = INT64_MIN;
pub const INTMAX_MAX = INT64_MAX;
pub const UINTMAX_MAX = UINT64_MAX;
pub const PTRDIFF_MIN = INT64_MIN;
pub const PTRDIFF_MAX = INT64_MAX;
pub const SIG_ATOMIC_MIN = INT32_MIN;
pub const SIG_ATOMIC_MAX = INT32_MAX;
pub const SIZE_MAX = UINT64_MAX;
pub const WCHAR_MIN = @as(c_uint, 0);
pub const WCHAR_MAX = @as(c_uint, 0xffff);
pub const WINT_MIN = @as(c_uint, 0);
pub const WINT_MAX = @as(c_uint, 0xffff);
pub inline fn INT8_C(val: anytype) @TypeOf((INT_LEAST8_MAX - INT_LEAST8_MAX) + val) {
    _ = &val;
    return (INT_LEAST8_MAX - INT_LEAST8_MAX) + val;
}
pub inline fn INT16_C(val: anytype) @TypeOf((INT_LEAST16_MAX - INT_LEAST16_MAX) + val) {
    _ = &val;
    return (INT_LEAST16_MAX - INT_LEAST16_MAX) + val;
}
pub inline fn INT32_C(val: anytype) @TypeOf((INT_LEAST32_MAX - INT_LEAST32_MAX) + val) {
    _ = &val;
    return (INT_LEAST32_MAX - INT_LEAST32_MAX) + val;
}
pub const INT64_C = __helpers.LL_SUFFIX;
pub inline fn UINT8_C(val: anytype) @TypeOf(val) {
    _ = &val;
    return val;
}
pub inline fn UINT16_C(val: anytype) @TypeOf(val) {
    _ = &val;
    return val;
}
pub const UINT32_C = __helpers.U_SUFFIX;
pub const UINT64_C = __helpers.ULL_SUFFIX;
pub const INTMAX_C = __helpers.LL_SUFFIX;
pub const UINTMAX_C = __helpers.ULL_SUFFIX;
pub const _INC_STRING = "";
pub const _INC_CORECRT_MEMORY = "";
pub const _WConst_return = "";
pub const _CRT_MEMORY_DEFINED = "";
pub const _NLSCMP_DEFINED = "";
pub const _NLSCMPERROR = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const _WSTRING_DEFINED = "";
pub const wcswcs = wcsstr;
pub const _INC_STRING_S = "";
pub const _WSTRING_S_DEFINED = "";
pub const _MATH_H_ = "";
pub const _DOMAIN = @as(c_int, 1);
pub const _SING = @as(c_int, 2);
pub const _OVERFLOW = @as(c_int, 3);
pub const _UNDERFLOW = @as(c_int, 4);
pub const _TLOSS = @as(c_int, 5);
pub const _PLOSS = @as(c_int, 6);
pub const DOMAIN = _DOMAIN;
pub const SING = _SING;
pub const OVERFLOW = _OVERFLOW;
pub const UNDERFLOW = _UNDERFLOW;
pub const TLOSS = _TLOSS;
pub const PLOSS = _PLOSS;
pub const M_E = @as(f64, 2.7182818284590452354);
pub const M_LOG2E = @as(f64, 1.4426950408889634074);
pub const M_LOG10E = @as(f64, 0.43429448190325182765);
pub const M_LN2 = @as(f64, 0.69314718055994530942);
pub const M_LN10 = @as(f64, 2.30258509299404568402);
pub const M_PI = @as(f64, 3.14159265358979323846);
pub const M_PI_2 = @as(f64, 1.57079632679489661923);
pub const M_PI_4 = @as(f64, 0.78539816339744830962);
pub const M_1_PI = @as(f64, 0.31830988618379067154);
pub const M_2_PI = @as(f64, 0.63661977236758134308);
pub const M_2_SQRTPI = @as(f64, 1.12837916709551257390);
pub const M_SQRT2 = @as(f64, 1.41421356237309504880);
pub const M_SQRT1_2 = @as(f64, 0.70710678118654752440);
pub const __MINGW_FPCLASS_DEFINED = @as(c_int, 1);
pub const _FPCLASS_SNAN = @as(c_int, 0x0001);
pub const _FPCLASS_QNAN = @as(c_int, 0x0002);
pub const _FPCLASS_NINF = @as(c_int, 0x0004);
pub const _FPCLASS_NN = @as(c_int, 0x0008);
pub const _FPCLASS_ND = @as(c_int, 0x0010);
pub const _FPCLASS_NZ = @as(c_int, 0x0020);
pub const _FPCLASS_PZ = @as(c_int, 0x0040);
pub const _FPCLASS_PD = @as(c_int, 0x0080);
pub const _FPCLASS_PN = @as(c_int, 0x0100);
pub const _FPCLASS_PINF = @as(c_int, 0x0200);
pub const __mingw_types_compatible_p = @compileError("unable to translate macro: undefined identifier `__builtin_types_compatible_p`");
// tools\zig\lib\libc\include\any-windows-any\math.h:95:9
pub const __mingw_choose_expr = @compileError("unable to translate macro: undefined identifier `__builtin_choose_expr`");
// tools\zig\lib\libc\include\any-windows-any\math.h:103:9
pub const __MINGW_SOFTMATH = "";
pub const _HUGE = __MINGW_IMP_SYMBOL(_HUGE).*;
pub const HUGE_VAL = @compileError("unable to translate macro: undefined identifier `__builtin_huge_val`");
// tools\zig\lib\libc\include\any-windows-any\math.h:149:9
pub const _EXCEPTION_DEFINED = "";
pub const MATH_ERRNO = @as(c_int, 1);
pub const MATH_ERREXCEPT = @as(c_int, 2);
pub const math_errhandling = MATH_ERRNO | MATH_ERREXCEPT;
pub const _CRT_ABS_DEFINED = "";
pub const _CRT_ATOF_DEFINED = "";
pub const EDOM = @as(c_int, 33);
pub const ERANGE = @as(c_int, 34);
pub const _COMPLEX_DEFINED = "";
pub const _CRT_MATHERR_DEFINED = "";
pub const _SIGN_DEFINED = "";
pub const FP_SNAN = _FPCLASS_SNAN;
pub const FP_QNAN = _FPCLASS_QNAN;
pub const FP_NINF = _FPCLASS_NINF;
pub const FP_PINF = _FPCLASS_PINF;
pub const FP_NDENORM = _FPCLASS_ND;
pub const FP_PDENORM = _FPCLASS_PD;
pub const FP_NZERO = _FPCLASS_NZ;
pub const FP_PZERO = _FPCLASS_PZ;
pub const FP_NNORM = _FPCLASS_NN;
pub const FP_PNORM = _FPCLASS_PN;
pub const HUGE_VALF = __builtin.huge_valf();
pub const HUGE_VALL = @compileError("unable to translate macro: undefined identifier `__builtin_huge_vall`");
// tools\zig\lib\libc\include\any-windows-any\math.h:353:9
pub const INFINITY = __builtin.inff();
pub const NAN = __builtin.nanf("");
pub const FP_NAN = @as(c_int, 0x0100);
pub const FP_NORMAL = @as(c_int, 0x0400);
pub const FP_INFINITE = FP_NAN | FP_NORMAL;
pub const FP_ZERO = @as(c_int, 0x4000);
pub const FP_SUBNORMAL = FP_NORMAL | FP_ZERO;
pub inline fn __dfp_expansion(__call: anytype, __fin: anytype, x: anytype) @TypeOf(__fin) {
    _ = &__call;
    _ = &__fin;
    _ = &x;
    return __fin;
}
pub const fpclassify = @compileError("unable to translate macro: undefined identifier `__builtin_trap`");
// tools\zig\lib\libc\include\any-windows-any\math.h:495:9
pub inline fn isfinite(x: anytype) @TypeOf((fpclassify(x) & FP_NAN) == @as(c_int, 0)) {
    _ = &x;
    return (fpclassify(x) & FP_NAN) == @as(c_int, 0);
}
pub inline fn isinf(x: anytype) @TypeOf(fpclassify(x) == FP_INFINITE) {
    _ = &x;
    return fpclassify(x) == FP_INFINITE;
}
pub const isnan = @compileError("unable to translate macro: undefined identifier `__builtin_trap`");
// tools\zig\lib\libc\include\any-windows-any\math.h:589:9
pub inline fn isnormal(x: anytype) @TypeOf(fpclassify(x) == FP_NORMAL) {
    _ = &x;
    return fpclassify(x) == FP_NORMAL;
}
pub const signbit = @compileError("unable to translate macro: undefined identifier `__builtin_trap`");
// tools\zig\lib\libc\include\any-windows-any\math.h:649:9
pub const FP_ILOGB0 = __helpers.cast(c_int, __helpers.promoteIntLiteral(c_int, 0x80000000, .hex));
pub const FP_ILOGBNAN = __helpers.cast(c_int, __helpers.promoteIntLiteral(c_int, 0x7fffffff, .hex));
pub inline fn _nan() @TypeOf(nan("")) {
    return nan("");
}
pub inline fn _nanf() @TypeOf(nanf("")) {
    return nanf("");
}
pub inline fn _nanl() @TypeOf(nanl("")) {
    return nanl("");
}
pub const isgreater = @compileError("unable to translate macro: undefined identifier `__builtin_isgreater`");
// tools\zig\lib\libc\include\any-windows-any\math.h:1023:9
pub const isgreaterequal = @compileError("unable to translate macro: undefined identifier `__builtin_isgreaterequal`");
// tools\zig\lib\libc\include\any-windows-any\math.h:1024:9
pub const isless = @compileError("unable to translate macro: undefined identifier `__builtin_isless`");
// tools\zig\lib\libc\include\any-windows-any\math.h:1025:9
pub const islessequal = @compileError("unable to translate macro: undefined identifier `__builtin_islessequal`");
// tools\zig\lib\libc\include\any-windows-any\math.h:1026:9
pub const islessgreater = @compileError("unable to translate macro: undefined identifier `__builtin_islessgreater`");
// tools\zig\lib\libc\include\any-windows-any\math.h:1027:9
pub const isunordered = @compileError("unable to translate macro: undefined identifier `__builtin_isunordered`");
// tools\zig\lib\libc\include\any-windows-any\math.h:1028:9
pub const _copysignl = copysignl;
pub const _hypotl = hypotl;
pub const matherr = _matherr;
pub const HUGE = _HUGE;
pub const QUICKJS_NG = @as(c_int, 1);
pub const JS_EXTERN = "";
pub const JS_LIBC_EXTERN = "";
pub const JS_MODULE_EXTERN = @compileError("unable to translate macro: undefined identifier `dllimport`");
// vendor/quickjs-ng/quickjs.h:109:11
pub const JS_PRINTF_FORMAT = "";
pub const JS_PRINTF_FORMAT_ATTR = @compileError("unable to translate macro: undefined identifier `format`");
// vendor/quickjs-ng/quickjs.h:129:9
pub inline fn JS_COUNT_ARGS_(_0: anytype, _8: anytype, _7: anytype, _6: anytype, _5: anytype, _4: anytype, _3: anytype, _2: anytype, _1: anytype, N: anytype) @TypeOf(N) {
    _ = &_0;
    _ = &_8;
    _ = &_7;
    _ = &_6;
    _ = &_5;
    _ = &_4;
    _ = &_3;
    _ = &_2;
    _ = &_1;
    _ = &N;
    return N;
}
pub const JS_COUNT_ARGS = @compileError("unable to translate C expr: unexpected token '__VA_ARGS__'");
// vendor/quickjs-ng/quickjs.h:143:9
pub const JS_CALLX1 = @compileError("unable to translate C expr: unexpected token 'do'");
// vendor/quickjs-ng/quickjs.h:145:9
pub const JS_CALLX2 = @compileError("unable to translate C expr: unexpected token 'do'");
// vendor/quickjs-ng/quickjs.h:146:9
pub const JS_CALLX3 = @compileError("unable to translate C expr: unexpected token 'do'");
// vendor/quickjs-ng/quickjs.h:147:9
pub const JS_CALLX4 = @compileError("unable to translate C expr: unexpected token 'do'");
// vendor/quickjs-ng/quickjs.h:148:9
pub const JS_CALLX5 = @compileError("unable to translate C expr: unexpected token 'do'");
// vendor/quickjs-ng/quickjs.h:149:9
pub const JS_CALLX6 = @compileError("unable to translate C expr: unexpected token 'do'");
// vendor/quickjs-ng/quickjs.h:150:9
pub const JS_CALLX7 = @compileError("unable to translate C expr: unexpected token 'do'");
// vendor/quickjs-ng/quickjs.h:151:9
pub const JS_CALLX8 = @compileError("unable to translate C expr: unexpected token 'do'");
// vendor/quickjs-ng/quickjs.h:152:9
pub const JS_CALLX__ = @compileError("unable to translate macro: undefined identifier `JS_CALLX`");
// vendor/quickjs-ng/quickjs.h:154:9
pub const JS_CALLX_ = @compileError("unable to translate C expr: unexpected token '__VA_ARGS__'");
// vendor/quickjs-ng/quickjs.h:155:9
pub const JSValueConst = JSValue;
pub inline fn JS_VALUE_GET_TAG(v: anytype) i32 {
    _ = &v;
    return __helpers.cast(i32, v.tag);
}
pub inline fn JS_VALUE_GET_NORM_TAG(v: anytype) @TypeOf(JS_VALUE_GET_TAG(v)) {
    _ = &v;
    return JS_VALUE_GET_TAG(v);
}
pub inline fn JS_VALUE_GET_INT(v: anytype) @TypeOf(v.u.int32) {
    _ = &v;
    return v.u.int32;
}
pub inline fn JS_VALUE_GET_BOOL(v: anytype) @TypeOf(v.u.int32) {
    _ = &v;
    return v.u.int32;
}
pub inline fn JS_VALUE_GET_FLOAT64(v: anytype) @TypeOf(v.u.float64) {
    _ = &v;
    return v.u.float64;
}
pub inline fn JS_VALUE_GET_SHORT_BIG_INT(v: anytype) @TypeOf(v.u.short_big_int) {
    _ = &v;
    return v.u.short_big_int;
}
pub inline fn JS_VALUE_GET_PTR(v: anytype) @TypeOf(v.u.ptr) {
    _ = &v;
    return v.u.ptr;
}
pub inline fn JS_MKPTR(tag: anytype, p: anytype) JSValue {
    _ = &tag;
    _ = &p;
    return @import("std").mem.zeroInit(JSValue, .{ @import("std").mem.zeroInit(JSValueUnion, .{
        .ptr = p,
    }), tag });
}
pub inline fn JS_MKVAL(tag: anytype, val: anytype) JSValue {
    _ = &tag;
    _ = &val;
    return @import("std").mem.zeroInit(JSValue, .{ @import("std").mem.zeroInit(JSValueUnion, .{
        .int32 = val,
    }), tag });
}
pub const JS_NAN = @import("std").mem.zeroInit(JSValue, .{ @import("std").mem.zeroInit(JSValueUnion, .{
    .float64 = NAN,
}), JS_TAG_FLOAT64 });
pub inline fn JS_TAG_IS_FLOAT64(tag: anytype) @TypeOf(__helpers.cast(c_uint, tag) == JS_TAG_FLOAT64) {
    _ = &tag;
    return __helpers.cast(c_uint, tag) == JS_TAG_FLOAT64;
}
pub inline fn JS_VALUE_IS_BOTH_INT(v1: anytype, v2: anytype) @TypeOf((JS_VALUE_GET_TAG(v1) | JS_VALUE_GET_TAG(v2)) == @as(c_int, 0)) {
    _ = &v1;
    _ = &v2;
    return (JS_VALUE_GET_TAG(v1) | JS_VALUE_GET_TAG(v2)) == @as(c_int, 0);
}
pub inline fn JS_VALUE_IS_BOTH_FLOAT(v1: anytype, v2: anytype) @TypeOf((JS_TAG_IS_FLOAT64(JS_VALUE_GET_TAG(v1)) != 0) and (JS_TAG_IS_FLOAT64(JS_VALUE_GET_TAG(v2)) != 0)) {
    _ = &v1;
    _ = &v2;
    return (JS_TAG_IS_FLOAT64(JS_VALUE_GET_TAG(v1)) != 0) and (JS_TAG_IS_FLOAT64(JS_VALUE_GET_TAG(v2)) != 0);
}
pub inline fn JS_VALUE_HAS_REF_COUNT(v: anytype) @TypeOf(__helpers.cast(c_uint, JS_VALUE_GET_TAG(v)) >= __helpers.cast(c_uint, JS_TAG_FIRST)) {
    _ = &v;
    return __helpers.cast(c_uint, JS_VALUE_GET_TAG(v)) >= __helpers.cast(c_uint, JS_TAG_FIRST);
}
pub const JS_NULL = JS_MKVAL(JS_TAG_NULL, @as(c_int, 0));
pub const JS_UNDEFINED = JS_MKVAL(JS_TAG_UNDEFINED, @as(c_int, 0));
pub const JS_FALSE = JS_MKVAL(JS_TAG_BOOL, @as(c_int, 0));
pub const JS_TRUE = JS_MKVAL(JS_TAG_BOOL, @as(c_int, 1));
pub const JS_EXCEPTION = JS_MKVAL(JS_TAG_EXCEPTION, @as(c_int, 0));
pub const JS_UNINITIALIZED = JS_MKVAL(JS_TAG_UNINITIALIZED, @as(c_int, 0));
pub const JS_PROP_CONFIGURABLE = @as(c_int, 1) << @as(c_int, 0);
pub const JS_PROP_WRITABLE = @as(c_int, 1) << @as(c_int, 1);
pub const JS_PROP_ENUMERABLE = @as(c_int, 1) << @as(c_int, 2);
pub const JS_PROP_C_W_E = (JS_PROP_CONFIGURABLE | JS_PROP_WRITABLE) | JS_PROP_ENUMERABLE;
pub const JS_PROP_LENGTH = @as(c_int, 1) << @as(c_int, 3);
pub const JS_PROP_TMASK = @as(c_int, 3) << @as(c_int, 4);
pub const JS_PROP_NORMAL = @as(c_int, 0) << @as(c_int, 4);
pub const JS_PROP_GETSET = @as(c_int, 1) << @as(c_int, 4);
pub const JS_PROP_VARREF = @as(c_int, 2) << @as(c_int, 4);
pub const JS_PROP_AUTOINIT = @as(c_int, 3) << @as(c_int, 4);
pub const JS_PROP_HAS_SHIFT = @as(c_int, 8);
pub const JS_PROP_HAS_CONFIGURABLE = @as(c_int, 1) << @as(c_int, 8);
pub const JS_PROP_HAS_WRITABLE = @as(c_int, 1) << @as(c_int, 9);
pub const JS_PROP_HAS_ENUMERABLE = @as(c_int, 1) << @as(c_int, 10);
pub const JS_PROP_HAS_GET = @as(c_int, 1) << @as(c_int, 11);
pub const JS_PROP_HAS_SET = @as(c_int, 1) << @as(c_int, 12);
pub const JS_PROP_HAS_VALUE = @as(c_int, 1) << @as(c_int, 13);
pub const JS_PROP_THROW = @as(c_int, 1) << @as(c_int, 14);
pub const JS_PROP_THROW_STRICT = @as(c_int, 1) << @as(c_int, 15);
pub const JS_PROP_NO_ADD = @as(c_int, 1) << @as(c_int, 16);
pub const JS_PROP_NO_EXOTIC = @as(c_int, 1) << @as(c_int, 17);
pub const JS_PROP_DEFINE_PROPERTY = @as(c_int, 1) << @as(c_int, 18);
pub const JS_PROP_REFLECT_DEFINE_PROPERTY = @as(c_int, 1) << @as(c_int, 19);
pub const JS_DEFAULT_STACK_SIZE = @as(c_int, 1024) * @as(c_int, 1024);
pub const JS_EVAL_TYPE_GLOBAL = @as(c_int, 0) << @as(c_int, 0);
pub const JS_EVAL_TYPE_MODULE = @as(c_int, 1) << @as(c_int, 0);
pub const JS_EVAL_TYPE_DIRECT = @as(c_int, 2) << @as(c_int, 0);
pub const JS_EVAL_TYPE_INDIRECT = @as(c_int, 3) << @as(c_int, 0);
pub const JS_EVAL_TYPE_MASK = @as(c_int, 3) << @as(c_int, 0);
pub const JS_EVAL_FLAG_STRICT = @as(c_int, 1) << @as(c_int, 3);
pub const JS_EVAL_FLAG_UNUSED = @as(c_int, 1) << @as(c_int, 4);
pub const JS_EVAL_FLAG_COMPILE_ONLY = @as(c_int, 1) << @as(c_int, 5);
pub const JS_EVAL_FLAG_BACKTRACE_BARRIER = @as(c_int, 1) << @as(c_int, 6);
pub const JS_EVAL_FLAG_ASYNC = @as(c_int, 1) << @as(c_int, 7);
pub const JS_DUMP_BYTECODE_FINAL = @as(c_int, 0x01);
pub const JS_DUMP_BYTECODE_PASS2 = @as(c_int, 0x02);
pub const JS_DUMP_BYTECODE_PASS1 = @as(c_int, 0x04);
pub const JS_DUMP_BYTECODE_HEX = @as(c_int, 0x10);
pub const JS_DUMP_BYTECODE_PC2LINE = @as(c_int, 0x20);
pub const JS_DUMP_BYTECODE_STACK = @as(c_int, 0x40);
pub const JS_DUMP_BYTECODE_STEP = @as(c_int, 0x80);
pub const JS_DUMP_READ_OBJECT = @as(c_int, 0x100);
pub const JS_DUMP_FREE = @as(c_int, 0x200);
pub const JS_DUMP_GC = @as(c_int, 0x400);
pub const JS_DUMP_GC_FREE = @as(c_int, 0x800);
pub const JS_DUMP_MODULE_RESOLVE = @as(c_int, 0x1000);
pub const JS_DUMP_PROMISE = @as(c_int, 0x2000);
pub const JS_DUMP_LEAKS = @as(c_int, 0x4000);
pub const JS_DUMP_ATOM_LEAKS = __helpers.promoteIntLiteral(c_int, 0x8000, .hex);
pub const JS_DUMP_MEM = __helpers.promoteIntLiteral(c_int, 0x10000, .hex);
pub const JS_DUMP_OBJECTS = __helpers.promoteIntLiteral(c_int, 0x20000, .hex);
pub const JS_DUMP_ATOMS = __helpers.promoteIntLiteral(c_int, 0x40000, .hex);
pub const JS_DUMP_SHAPES = __helpers.promoteIntLiteral(c_int, 0x80000, .hex);
pub const JS_ABORT_ON_LEAKS = __helpers.promoteIntLiteral(c_int, 0x10C000, .hex);
pub const JS_ATOM_NULL = @as(c_int, 0);
pub const JS_FreeAtoms = @compileError("unable to translate C expr: unexpected token '__VA_ARGS__'");
// vendor/quickjs-ng/quickjs.h:619:9
pub const JS_FreeAtomsRT = @compileError("unable to translate C expr: unexpected token '__VA_ARGS__'");
// vendor/quickjs-ng/quickjs.h:620:9
pub const JS_CALL_FLAG_CONSTRUCTOR = @as(c_int, 1) << @as(c_int, 0);
pub const JS_EVAL_OPTIONS_VERSION = @as(c_int, 1);
pub const JS_INVALID_CLASS_ID = @as(c_int, 0);
pub const JS_FreeValues = @compileError("unable to translate C expr: unexpected token '__VA_ARGS__'");
// vendor/quickjs-ng/quickjs.h:865:9
pub const JS_FreeValuesRT = @compileError("unable to translate C expr: unexpected token '__VA_ARGS__'");
// vendor/quickjs-ng/quickjs.h:866:9
pub const JS_GPN_STRING_MASK = @as(c_int, 1) << @as(c_int, 0);
pub const JS_GPN_SYMBOL_MASK = @as(c_int, 1) << @as(c_int, 1);
pub const JS_GPN_PRIVATE_MASK = @as(c_int, 1) << @as(c_int, 2);
pub const JS_GPN_ENUM_ONLY = @as(c_int, 1) << @as(c_int, 4);
pub const JS_GPN_SET_ENUM = @as(c_int, 1) << @as(c_int, 5);
pub const JS_WRITE_OBJ_BYTECODE = @as(c_int, 1) << @as(c_int, 0);
pub const JS_WRITE_OBJ_BSWAP = @as(c_int, 0);
pub const JS_WRITE_OBJ_SAB = @as(c_int, 1) << @as(c_int, 2);
pub const JS_WRITE_OBJ_REFERENCE = @as(c_int, 1) << @as(c_int, 3);
pub const JS_WRITE_OBJ_STRIP_SOURCE = @as(c_int, 1) << @as(c_int, 4);
pub const JS_WRITE_OBJ_STRIP_DEBUG = @as(c_int, 1) << @as(c_int, 5);
pub const JS_READ_OBJ_BYTECODE = @as(c_int, 1) << @as(c_int, 0);
pub const JS_READ_OBJ_ROM_DATA = @as(c_int, 0);
pub const JS_READ_OBJ_SAB = @as(c_int, 1) << @as(c_int, 2);
pub const JS_READ_OBJ_REFERENCE = @as(c_int, 1) << @as(c_int, 3);
pub const JS_DEF_CFUNC = @as(c_int, 0);
pub const JS_DEF_CGETSET = @as(c_int, 1);
pub const JS_DEF_CGETSET_MAGIC = @as(c_int, 2);
pub const JS_DEF_PROP_STRING = @as(c_int, 3);
pub const JS_DEF_PROP_INT32 = @as(c_int, 4);
pub const JS_DEF_PROP_INT64 = @as(c_int, 5);
pub const JS_DEF_PROP_DOUBLE = @as(c_int, 6);
pub const JS_DEF_PROP_UNDEFINED = @as(c_int, 7);
pub const JS_DEF_OBJECT = @as(c_int, 8);
pub const JS_DEF_ALIAS = @as(c_int, 9);
pub const JS_DEF_PROP_SYMBOL = @as(c_int, 10);
pub const JS_DEF_PROP_BOOL = @as(c_int, 11);
pub const JS_CFUNC_DEF = @compileError("unable to translate C expr: unexpected token '{'");
// vendor/quickjs-ng/quickjs.h:1415:9
pub const JS_CFUNC_DEF2 = @compileError("unable to translate C expr: unexpected token '{'");
// vendor/quickjs-ng/quickjs.h:1416:9
pub const JS_CFUNC_MAGIC_DEF = @compileError("unable to translate C expr: unexpected token '{'");
// vendor/quickjs-ng/quickjs.h:1417:9
pub const JS_CFUNC_SPECIAL_DEF = @compileError("unable to translate macro: undefined identifier `JS_CFUNC_`");
// vendor/quickjs-ng/quickjs.h:1418:9
pub const JS_ITERATOR_NEXT_DEF = @compileError("unable to translate C expr: unexpected token '{'");
// vendor/quickjs-ng/quickjs.h:1419:9
pub const JS_CGETSET_DEF = @compileError("unable to translate C expr: unexpected token '{'");
// vendor/quickjs-ng/quickjs.h:1420:9
pub const JS_CGETSET_DEF2 = @compileError("unable to translate C expr: unexpected token '{'");
// vendor/quickjs-ng/quickjs.h:1421:9
pub const JS_CGETSET_MAGIC_DEF = @compileError("unable to translate C expr: unexpected token '{'");
// vendor/quickjs-ng/quickjs.h:1422:9
pub const JS_CGETSET_MAGIC_DEF2 = @compileError("unable to translate C expr: unexpected token '{'");
// vendor/quickjs-ng/quickjs.h:1423:9
pub const JS_PROP_STRING_DEF = @compileError("unable to translate C expr: unexpected token '{'");
// vendor/quickjs-ng/quickjs.h:1424:9
pub const JS_PROP_INT32_DEF = @compileError("unable to translate C expr: unexpected token '{'");
// vendor/quickjs-ng/quickjs.h:1425:9
pub const JS_PROP_INT64_DEF = @compileError("unable to translate C expr: unexpected token '{'");
// vendor/quickjs-ng/quickjs.h:1426:9
pub const JS_PROP_DOUBLE_DEF = @compileError("unable to translate C expr: unexpected token '{'");
// vendor/quickjs-ng/quickjs.h:1427:9
pub const JS_PROP_U2D_DEF = @compileError("unable to translate C expr: unexpected token '{'");
// vendor/quickjs-ng/quickjs.h:1428:9
pub const JS_PROP_UNDEFINED_DEF = @compileError("unable to translate C expr: unexpected token '{'");
// vendor/quickjs-ng/quickjs.h:1429:9
pub const JS_PROP_SYMBOL_DEF = @compileError("unable to translate C expr: unexpected token '{'");
// vendor/quickjs-ng/quickjs.h:1430:9
pub const JS_PROP_BOOL_DEF = @compileError("unable to translate C expr: unexpected token '{'");
// vendor/quickjs-ng/quickjs.h:1431:9
pub const JS_OBJECT_DEF = @compileError("unable to translate C expr: unexpected token '{'");
// vendor/quickjs-ng/quickjs.h:1432:9
pub const JS_ALIAS_DEF = @compileError("unable to translate C expr: unexpected token '{'");
// vendor/quickjs-ng/quickjs.h:1433:9
pub const JS_ALIAS_BASE_DEF = @compileError("unable to translate C expr: unexpected token '{'");
// vendor/quickjs-ng/quickjs.h:1434:9
pub const QJS_VERSION_MAJOR = @as(c_int, 0);
pub const QJS_VERSION_MINOR = @as(c_int, 17);
pub const QJS_VERSION_PATCH = @as(c_int, 0);
pub const QJS_VERSION_SUFFIX = "";
pub const threadlocaleinfostruct = struct_threadlocaleinfostruct;
pub const threadmbcinfostruct = struct_threadmbcinfostruct;
pub const __lc_time_data = struct___lc_time_data;
pub const localeinfo_struct = struct_localeinfo_struct;
pub const tagLC_ID = struct_tagLC_ID;
pub const _iobuf = struct__iobuf;
pub const _exception = struct__exception;
pub const _complex = struct__complex;
