/// SQLite3 Database engine - statically linked .obj for Windows/Linux 32 bit
// - this unit is a part of the freeware Synopse mORMot framework,
// licensed under a MPL/GPL/LGPL tri-license; version 1.18
unit SynSQLite3Static;

{
    This file is part of Synopse mORMot framework.

    Synopse mORMot framework. Copyright (C) 2015 Arnaud Bouchez
      Synopse Informatique - http://synopse.info

  *** BEGIN LICENSE BLOCK *****
  Version: MPL 1.1/GPL 2.0/LGPL 2.1

  The contents of this file are subject to the Mozilla Public License Version
  1.1 (the "License"); you may not use this file except in compliance with
  the License. You may obtain a copy of the License at
  http://www.mozilla.org/MPL

  Software distributed under the License is distributed on an "AS IS" basis,
  WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License
  for the specific language governing rights and limitations under the License.

  The Original Code is Synopse mORMot framework.

  The Initial Developer of the Original Code is Arnaud Bouchez.

  Portions created by the Initial Developer are Copyright (C) 2015
  the Initial Developer. All Rights Reserved.

  Contributor(s):
   Alfred Glaenzer (alf)

  Alternatively, the contents of this file may be used under the terms of
  either the GNU General Public License Version 2 or later (the "GPL"), or
  the GNU Lesser General Public License Version 2.1 or later (the "LGPL"),
  in which case the provisions of the GPL or the LGPL are applicable instead
  of those above. If you wish to allow use of your version of this file only
  under the terms of either the GPL or the LGPL, and not to allow others to
  use your version of this file under the terms of the MPL, indicate your
  decision by deleting the provisions above and replace them with the notice
  and other provisions required by the GPL or the LGPL. If you do not delete
  the provisions above, a recipient may use your version of this file under
  the terms of any one of the MPL, the GPL or the LGPL.

  ***** END LICENSE BLOCK *****



    Statically linked SQLite3 3.8.8.3 engine
   ******************************************

  To be declared in your project uses clause:  will fill SynSQlite3.sqlite3
  global variable with all statically linked .obj API entries.
  sqlite3 := TSQLite3LibraryStatic.Create; is called at unit initialization.

  Will work only on Windows 32 bit (with Delphi or FPC, with expected .obj / .o)
  or Linux 32 bit (with FPC, with the corresponding .o)
  under other platforms, this unit will just do nothing (but compile).
  
  To compile our patched SQlite3.c version, available in this source folder:
  - Run c.bat to compile the sqlite3*.obj for Win32/Delphi
  - Run c-fpcmingw.bat to compile sqlite3.o for Win32/FPC
  - Run c-fpcgcclin.sh to compile sqlite3.o for Linux32/FPC

  Uses TSQLite3LibraryDynamic to access external library (e.g. sqlite3.dll/.so)

  To retrieve and install the latest sqlite3 debian package on Ubuntu:
  - retrieve latest .deb from https://launchpad.net/ubuntu/...
  - for a 32 bit system, install e.g. as
    sudo dpkg -i libsqlite3-0_3.8.7.4-1_i386.deb
  - for a 64 bit system, you need to download and install both packages, e.g.
    sudo dpkg -i libsqlite3-0_3.8.2-1ubuntu2_amd64.deb libsqlite3-0_3.8.2-1ubuntu2_i386.deb

  Version 1.18
  - initial revision, extracted from SynSQLite3.pas unit
  - updated SQLite3 engine to latest version 3.8.8.3
  - now all sqlite3_*() API calls are accessible via sqlite3.*()
  - our custom file encryption is now called via sqlite3.key() - i.e. official
    SQLite Encryption Extension (SEE) sqlite3_key() API
  - Memory-Mapped I/O support - see http://www.sqlite.org/mmap.html
  - under Win64, expects an external sqlite3-64.dll file to be available
  - added sqlite3.backup_*() Online Backup API functions 
  - added missing function sqlite3_column_text16() - fixed ticket [25d8d1f47a]


}

{$I Synopse.inc} // define HASINLINE CPU32 CPU64 OWNNORMTOUPPER SQLITE3_FASTCALL

interface

{$ifdef NOSQLITE3STATIC}
uses
  SysUtils,
  SynSQLite3;

implementation


procedure DoInitialization;
begin
  FreeAndNil(sqlite3);
  try
    sqlite3 := TSQLite3LibraryDynamic.Create(SQLITE_LIBRARY_DEFAULT_NAME);        
    sqlite3.ForceToUseSharedMemoryManager; // faster process
  except
    on E: Exception do  
      {$ifdef LINUX}
      writeln(SQLITE_LIBRARY_DEFAULT_NAME+' initialization failed with ',
        E.ClassName,': ',E.Message);
      {$endif}
  end;
end;

initialization
  DoInitialization;

{$else}
uses
  {$ifdef MSWINDOWS}
  Windows,
  {$else}
  {$ifdef FPC}
  SynFPCLinux,
  BaseUnix,
  {$endif}
  {$ifdef KYLIX3}
  Types,
  LibC,
  SynKylix,
  {$endif}
  {$endif}
  Classes,
  SysUtils,
  SynCommons,
  SynSQLite3;


{$ifdef INCLUDE_FTS3}
  {$define INCLUDE_TRACE}
  { define this is you want to include the TRACE feature into the library
   - our C source code custom header will define SQLITE_OMIT_TRACE if FTS3/FST4
   is not defined }
{$endif}

type
  /// access class to the static .obj SQLite3 engine
  // - the intialization section of this unit calls:
  // ! sqlite3 := TSQLite3LibraryStatic.Create;
  // therefore, adding SynSQLite3Static to your uses clause is enough to use
  // the statically linked SQLite3 engine with SynSQLite3
  TSQLite3LibraryStatic = class(TSQLite3Library)
  public
    /// fill the internal API reference s with the static .obj engine
    constructor Create; reintroduce;
    /// unload the static library
    destructor Destroy; override;
  end;


{$ifndef NOSQLITE3ENCRYPT}
/// use this procedure to change the password for an existing SQLite3 database file
// - use this procedure instead of the "classic" sqlite3.rekey() API call
// - conversion is done in-place, therefore this procedure can handle very big files
// - the OldPassWord must be correct, otherwise the resulting file will be corrupted
// - any password can be '' to mark no encryption
// - you may use instead SynCrypto unit for more secure SHA-256 and AES-256 algos
// - please note that this encryption is compatible only with SQlite3 files
// using the default page size of 1024
// - implementation is NOT compatible with the official SQLite Encryption Extension
// (SEE) file format: it provides only simple XOR encryption (no RC4/AES)
// - the first page (first 1024 bytes) is not encrypted, since its content
// (mostly zero) can be used to easily guess the beginning of the key
// - if the key is not correct, a ESQLite3Exception will be raised with
// 'database disk image is malformed' (SQLITE_CORRUPT) at database opening 
procedure ChangeSQLEncryptTablePassWord(const FileName: TFileName;
  const OldPassWord, NewPassword: RawUTF8);
{$endif}

implementation


const
  /// encryption XOR mask table size (in bytes)
  // - must be a power of 2
  // - bigger encryption table makes stronger encryption, but use more memory
  // - it's faster when the mask table can stay in the CPU L1 cache
  // - default size is therefore 16KB
  SQLEncryptTableSize = $4000;

{
  Code below will link all database engine, from amalgamation source file:

 - to compile with free Borland C++ compiler 5.5.1 from the command line:
     \dev\bcc\bin\bcc32 -6 -O2 -c -d -u- sqlite3.c
    FastCall use must be set with defining SQLITE3_FASTCALL above, and
     int __cdecl fts3CompareElemByTerm(const void *lhs, const void *rhs)
     \dev\bcc\bin\bcc32 -6 -O2 -c -d -pr -u- sqlite3.c
 - to compile for FPC using the MinGW compiler: run c-fpcmingw.bat
    gcc -O2 -c -DSQLITE_ENABLE_FTS3 -DSQLITE_ENABLE_FTS4 -DSQLITE_ENABLE_FTS3_PARENTHESIS sqlite3.c
    and copy libgcc.a and libkernel32.a from your MinGW folders
 - to compile for FPC using gcc under Linux: run c-fpcgcclin.sh
    gcc -O2 -c -lpthread -ldl -DSQLITE_ENABLE_FTS3 -DSQLITE_ENABLE_FTS4 -DSQLITE_ENABLE_FTS3_PARENTHESIS -DSQLITE_ENABLE_RTREE sqlite3.c
    and copy the libgcc.a and sqlite3.o (and libc.a if needed) into the linuxlibrary folder and off you go
    For CentOS 7.0, take a look at http://synopse.info/forum/viewtopic.php?pid=13193#p13193

 - the following defines must be added in the beginning of the sqlite3.c file:

//#define SQLITE_ENABLE_FTS3
//  this unit is FTS3-ready, but not compiled with it by default
//  if you don't use FTS3, dont define this conditional: you'll spare 50KB of code
//  this conditional is defined at compile time, in order to create sqlite3fts3.obj
#define SQLITE_DEFAULT_MEMSTATUS 0
//  don't need any debug here
#define SQLITE_THREADSAFE 2
//  assuming multi-thread safety is made by caller - in our framework, there is
// only one thread using the database connection at the same time, but there could
// be multiple database connection at the same time (previous was 0 could be unsafe)
#define SQLITE_OMIT_SHARED_CACHE 1
// no need of shared cache in a threadsafe calling model
#define SQLITE_OMIT_AUTOINIT 1
//  sqlite3.initialize() is done in initialization section below -> no AUTOINIT
#define SQLITE_OMIT_DEPRECATED 1
//  spare some code size - is now defined only if compiled without FTS3/FTS4
#ifndef SQLITE_ENABLE_FTS3
  #define SQLITE_OMIT_TRACE 1
#endif
// we don't need sqlite3.profile() and sqlite3.trace() interfaces
#define SQLITE_OMIT_LOAD_EXTENSION 1
// we don't need extension in an embedded engine
#define SQLITE_OMIT_COMPILEOPTION_DIAGS 1
// we don't need Compilation Options Diagnostics in our embedded engine
#define SQLITE_OMIT_PROGRESS_CALLBACK 1
// we don't need sqlite3.progress_handler() API function
#define SQLITE_ENABLE_RTREE 1
// the RTREE extension is now (from v.1.8/3.7) compiled into the engine
//#define SQLITE_OMIT_LOOKASIDE
// even if we use FastMM4/SynScaleMM, LookAside seems mandatory in c source
#define SQLITE_WITHOUT_MSIZE
// _msize() is not available (nor needed) with FastMM4 memory manager

and, in the sqlite3.c source file, the following functions are made external
in order to allow our proprietary but simple and efficient encryption system:

extern int winRead(
  sqlite3.file *id,          /* File to read from */
  void *pBuf,                /* Write content into this buffer */
  int amt,                   /* Number of bytes to read */
  sqlite3.int64 offset       /* Begin reading at this offset */
);

extern int winWrite(
  sqlite3.file *id,         /* File to write into */
  const void *pBuf,         /* The bytes to be written */
  int amt,                  /* Number of bytes to write */
  sqlite3.int64 offset      /* Offset into the file to begin writing at */
);

Under Linux (thanks Alf for the patch!), change the following lines of sqlite3.c:

extern int unixRead(
  sqlite3_file *id,
  void *pBuf,
  int amt,
  sqlite3_int64 offset
);

extern int unixWrite(
  sqlite3_file *id,
  const void *pBuf,
  int amt,
  sqlite3_int64 offset
);

}

{$ifdef FPC}  // FPC expects .o linking, and only one version including FTS3
  {$ifdef MSWINDOWS}
  {$L fpc-win32\sqlite3.o}
  {$linklib fpc-win32\libkernel32.a}
  {$linklib fpc-win32\libgcc.a}
  {$else}
  {$L fpc-linux32\sqlite3.o}
  {$linklib fpc-linux32\gcc.a}
  {$endif MSWINDOWS}
{$else}
  {$ifdef MSWINDOWS} // Delphi
    {$ifdef INCLUDE_FTS3}
    {$L sqlite3fts3.obj}   // link SQlite3 database engine with FTS3/FTS4 + TRACE
    {$else}
    {$L sqlite3.obj}       // link SQlite3 database engine
    {$endif INCLUDE_FTS3}
  {$else}
  {$ifdef KYLIX3}
  {$L kylix/sqlite3/sqlite3.o}
  {$L kylix/sqlite3/_divdi3.o}
  {$L kylix/sqlite3/_moddi3.o}
  {$L kylix/sqlite3/_udivdi3.o}
  {$L kylix/sqlite3/_umoddi3.o}
  {$L kylix/sqlite3/_cmpdi2.o}
  {$endif KYLIX3}
  {$endif MSWINDOWS}
{$endif}

// we then implement all needed Borland C++ runtime functions in pure pascal:

{$ifndef FPC}
function _ftol: Int64;
// Borland C++ float to integer (Int64) conversion
asm
  jmp System.@Trunc  // FST(0) -> EDX:EAX, as expected by BCC32 compiler
end;

function _ftoul: Int64;
// Borland C++ float to integer (Int64) conversion
asm
  jmp System.@Trunc  // FST(0) -> EDX:EAX, as expected by BCC32 compiler
end;
{$endif FPC}

// those functions will be called only under Windows

function malloc(size: cardinal): Pointer; cdecl; { always cdecl }
  {$ifdef FPC}alias : '_malloc';{$endif}
// the SQLite3 database engine will use the FastMM4/SynScaleMM fast heap manager
begin
  GetMem(Result, size);
end;

procedure free(P: Pointer); cdecl; { always cdecl }
  {$ifdef FPC}alias : '_free';{$endif}
// the SQLite3 database engine will use the FastMM4 very fast heap manager
begin
  FreeMem(P);
end;

function realloc(P: Pointer; Size: Integer): Pointer; cdecl; { always cdecl }
  {$ifdef FPC}alias : '_realloc';{$endif}
// the SQLite3 database engine will use the FastMM4/SynScaleMM very fast heap manager
begin
  result := P;
  ReallocMem(result,Size);
end;

function memset(P: Pointer; B: Integer; count: Integer): pointer; cdecl; { always cdecl }
  {$ifdef FPC}alias : '_memset';{$endif}
// a fast full pascal version of the standard C library function
begin
  result := P;
  FillChar(P^, count, B);
end;

procedure memmove(dest, source: pointer; count: Integer); cdecl; { always cdecl }
  {$ifdef FPC}alias : '_memmove';{$endif}
// a fast full pascal version of the standard C library function
begin
  Move(source^, dest^, count); // move() is overlapping-friendly
end;

procedure memcpy(dest, source: Pointer; count: Integer); cdecl; { always cdecl }
  {$ifdef FPC}alias : '_memcpy';{$endif}
// a fast full pascal version of the standard C library function
begin
  Move(source^, dest^, count);
end;

{$ifndef FPC}
{$ifdef MSWINDOWS}

var __turbofloat: word; { not used, but must be present for linking }

// Borland C++ and Delphi share the same low level Int64 _ll*() functions:

procedure _lldiv;
asm
  jmp System.@_lldiv
end;

procedure _lludiv;
asm
  jmp System.@_lludiv
end;

procedure _llmod;
asm
  jmp System.@_llmod
end;

procedure _llmul;
asm
  jmp System.@_llmul
end;

procedure _llumod;
asm
  jmp System.@_llumod
end;

procedure _llshl;
asm
  jmp System.@_llshl
end;

procedure _llshr;
asm
{$ifndef ENHANCEDRTL} // need this code for Borland/CodeGear default System.pas
  shrd    eax, edx, cl
  sar     edx, cl
  cmp     cl, 32
  jl      @@Done
  cmp     cl, 64
  jge     @@RetSign
  mov     eax, edx
  sar     edx, 31
  ret
@@RetSign:
  sar     edx, 31
  mov     eax, edx
@@Done:
{$else}
  // our customized System.pas didn't forget to put _llshr in its interface :)
  jmp System.@_llshr
{$endif}
end;

procedure _llushr;
asm
  jmp System.@_llushr
end;

{$endif MSWINDOWS}
{$endif FPC}

function strlen(p: PAnsiChar): integer; cdecl; { always cdecl }
  {$ifdef FPC}alias : '_strlen';{$endif}
// a fast full pascal version of the standard C library function
begin // called only by some obscure FTS3 functions (normal code use dedicated functions)
  result := SynCommons.StrLen(pointer(p));
end;

function strcmp(p1,p2: PAnsiChar): integer; cdecl; { always cdecl }
  {$ifdef FPC}alias : '_strcmp';{$endif}
// a fast full pascal version of the standard C library function
begin // called only by some obscure FTS3 functions (normal code use dedicated functions)
  result := SynCommons.StrComp(p1,p2);
end;

function memcmp(p1, p2: pByte; Size: integer): integer; cdecl; { always cdecl }
  {$ifdef FPC}alias : '_memcmp';{$endif}
// a fast full pascal version of the standard C library function
begin
  if (p1<>p2) and (Size<>0) then
    if p1<>nil then
      if p2<>nil then begin
        repeat
          if p1^<>p2^ then begin
            result := p1^-p2^;
            exit;
          end;
          dec(Size);
          inc(p1);
          inc(p2);
        until Size=0;
        result := 0;
      end else
      result := 1 else
    result := -1 else
  result := 0;
end;

function strncmp(p1, p2: PByte; Size: integer): integer; cdecl; { always cdecl }
  {$ifdef FPC}alias : '_strncmp';{$endif}
// a fast full pascal version of the standard C library function
var i: integer;
begin
  for i := 1 to Size do begin
    result := p1^-p2^;
    if (result<>0) or (p1^=0) then
      exit;
    inc(p1);
    inc(p2);
  end;
  result := 0;
end;

// qsort() is used if SQLITE_ENABLE_FTS3 is defined
type // this function type is defined for calling termDataCmp() in sqlite3.c
  qsort_compare_func = function(P1,P2: pointer): integer; cdecl; { always cdecl }

procedure QuickSort4(base: PPointerArray; L, R: Integer; comparF: qsort_compare_func);
var I, J, P: Integer;
    PP, C: PAnsiChar;
begin
  repeat // from SQLite (FTS), With=sizeof(PAnsiChar) AFAIK
    I := L;
    J := R;
    P := (L+R) shr 1;
    repeat
      PP := @base[P];
      while comparF(@base[I],PP)<0 do
        inc(I);
      while comparF(@base[J],PP)>0 do
        dec(J);
      if I<=J then begin
        C := base[I];
        base[I] := base[J];
        base[J] := C; // fast memory exchange
        if P=I then P := J else if P=J then P := I;
        inc(I);
        dec(J);
      end;
    until I>J;
    if L<J then
      QuickSort4(base, L, J, comparF);
    L := I;
  until I>=R;
end;

procedure QuickSort(baseP: PAnsiChar; Width: integer; L, R: Integer; comparF: qsort_compare_func);
// code below is very fast and optimized
  procedure Exchg(P1,P2: PAnsiChar; Size: integer);
  var B: AnsiChar;
      i: integer;
  begin
    for i := 0 to Size-1 do begin
      B := P1[i];
      P1[i] := P2[i];
      P2[i] := B;
    end;
  end;
var I, J, P: Integer;
    PP, C: PAnsiChar;
begin
  repeat // generic sorting algorithm
    I := L;
    J := R;
    P := (L+R) shr 1;
    repeat
      PP := baseP+P*Width; // compute PP at every loop, since P may change
      C := baseP+I*Width;
      while comparF(C,PP)<0 do begin
        inc(I);
        inc(C,width); // avoid slower multiplication in loop
      end;
      C := baseP+J*Width;
      while comparF(C,PP)>0 do begin
        dec(J);
        dec(C,width); // avoid slower multiplication in loop
      end;
      if I<=J then begin
        Exchg(baseP+I*Width,baseP+J*Width,Width); // fast memory exchange
        if P=I then P := J else if P=J then P := I;
        inc(I);
        dec(J);
      end;
    until I>J;
    if L<J then
      QuickSort(baseP, Width, L, J, comparF);
    L := I;
  until I>=R;
end;

procedure qsort(baseP: pointer; NElem, Width: integer; comparF: qsort_compare_func);
  cdecl; { always cdecl }
  {$ifdef FPC}alias : '_qsort';{$endif}
// a fast full pascal version of the standard C library function
begin
  if (cardinal(NElem)>1) and (Width>0) then
    if Width=sizeof(pointer) then
      QuickSort4(baseP, 0, NElem-1, comparF) else
      QuickSort(baseP, Width, 0, NElem-1, comparF);
end;

var
  { as standard C library documentation states:
  Statically allocated buffer, shared by the functions gmtime() and localtime().
  Each call of these functions overwrites the content of this structure.
  -> since timing is not thread-dependent, it's OK to share this buffer :) }
  atm: packed record
    tm_sec: Integer;            { Seconds.      [0-60] (1 leap second) }
    tm_min: Integer;            { Minutes.      [0-59]  }
    tm_hour: Integer;           { Hours.        [0-23]  }
    tm_mday: Integer;           { Day.          [1-31]  }
    tm_mon: Integer;            { Month.        [0-11]  }
    tm_year: Integer;           { Year          - 1900. }
    tm_wday: Integer;           { Day of week.  [0-6]   }
    tm_yday: Integer;           { Days in year. [0-365] }
    tm_isdst: Integer;          { DST.          [-1/0/1]}
    __tm_gmtoff: Integer;       { Seconds east of UTC.  }
    __tm_zone: ^Char;           { Timezone abbreviation.}
  end;

function localtime64(const t: Int64): pointer; cdecl; { always cdecl }
  {$ifdef FPC}alias : '__localtime64';{$endif}
// a fast full pascal version of the standard C library function
var {$ifdef MSWINDOWS}
    uTm: TFileTime;
    lTm: TFileTime;
    {$endif}
    S: TSystemTime;
begin
  {$ifdef MSWINDOWS}
  Int64(uTm) := (t+11644473600)*10000000; // unix time to dos file time
  FileTimeToLocalFileTime(uTM,lTM);
  FileTimeToSystemTime(lTM,S);
  atm.tm_sec := S.wSecond;
  atm.tm_min := S.wMinute;
  atm.tm_hour := S.wHour;
  atm.tm_mday := S.wDay;
  atm.tm_mon := S.wMonth-1;
  atm.tm_year := S.wYear-1900;
  atm.tm_wday := S.wDayOfWeek;
  {$else}
  GetNowUTCSystem(S);
  atm.tm_sec := S.Second;
  atm.tm_min := S.Minute;
  atm.tm_hour := S.Hour;
  atm.tm_mday := S.Day;
  atm.tm_mon := S.Month-1;
  atm.tm_year := S.Year-1900;
  atm.tm_wday := S.Day;
  {$endif}
  result := @atm;
end;

function localtime(t: PCardinal): pointer; cdecl; { always cdecl }
  {$ifdef FPC}alias : '_localtime';{$endif}
begin
  result := localtime64(t^);
end;

{$ifdef MSWINDOWS}
function _beginthreadex(security: pointer; stksize: dword;
  start,arg: pointer; flags: dword; var threadid: dword): THandle; cdecl;
  {$ifdef FPC}alias : '__beginthreadex';{$endif}
begin
  result := CreateThread(security,stkSize,start,arg,flags,threadid);
end;

procedure _endthreadex(ExitCode: DWORD); cdecl;
  {$ifdef FPC}alias : '__endthreadex';{$endif}
begin
  ExitThread(ExitCode);
end;

{$else MSWINDOWS}

{$ifdef FPC}
function newstat64(path: pchar; buf: PStat): cint; cdecl;
  alias: 'stat64'; export;
begin
  result := fpstat(path,buf^);
end;

function newfstat64(fd: cint; buf: PStat): cint; cdecl;
  alias: 'fstat64'; export;
begin
  result := fpfstat(fd,buf^);
end;
{$endif FPC}

{$ifdef KYLIX3}

function close(Handle: Integer): Integer; cdecl;
  external libcmodulename;
function read(Handle: Integer; var Buffer; Count: size_t): ssize_t; cdecl;
  external libcmodulename;
function write(Handle: Integer; const Buffer; Count: size_t): ssize_t; cdecl;
  external libcmodulename;

function __fixunsdfdi(a: double): Int64; cdecl;
begin
  if a<0 then
    result := 0 else
    result := round(a);
end;

{$endif}

{$endif MSWINDOWS}

procedure CreateSQLEncryptTableBytes(const PassWord: RawUTF8; Table: PByteArray);
// very fast table (private key) computation from a given password
// - use a simple prime-based random generator, strong enough for common use
// - execution speed and code size was the goal here: can be easily broken
// - SynCrypto proposes SHA-256 and AES-256 for more secure encryption
var i, j, k, L: integer;
begin
  L := length(Password)-1;
  j := 0;
  k := integer(L*ord(Password[1]))+134775813; // initial value, prime number derivated
  for i := 0 to SQLEncryptTableSize-1 do begin
    Table^[i] := (ord(PassWord[j+1])) xor byte(k);
    k := Integer(k*3+i); // fast prime-based pseudo random generator
    if j=L then
      j := 0 else
      inc(j);
  end;
end;

// XorOffset: fast and simple Cypher using Index (= offset in file)
// -> not to be set as local proc for FPC
// see http://bugs.freepascal.org/view.php?id=24061
procedure Xor64(PI, P: PPtrIntArray; Count: cardinal); // fast xor
{$ifdef PUREPASCAL}
var i: cardinal;
begin
  for i := 0 to (Count div sizeof(PtrInt))-1 do
    P^[i] := P^[i] xor PI^[i]; // this will compile fine for 64 bit CPU
end;
{$else}
asm // eax=PI edx=P ecx=bytes count
  push ebx
  push esi
  shr ecx,3 // 64 bits = 8 bytes per loop
  jz @z
@1:
  mov ebx,[eax]    // fast CPU-pipelined optimized loop
  mov esi,[eax+4]
  xor [edx],ebx
  xor [edx+4],esi
  dec ecx
  lea eax,[eax+8]
  lea edx,[edx+8]
  jnz @1
@z:
  pop esi
  pop ebx
end;
{$endif}

procedure XorOffset(p: pByte; Index, Count: cardinal; SQLEncryptTable: PByteArray);
var i, Len, L: integer;
begin
  if Count>0 then
  repeat
    Index := Index and (SQLEncryptTableSize-1);
    Len := SQLEncryptTableSize-Index;
    if cardinal(Len)>cardinal(Count) then
      Len := Count;
    Xor64(@SQLEncryptTable^[Index],pointer(p),Len); // xor 8 bytes per loop
    L := Len and (-8); // -8=$FFFFFFF8
    inc(p,L);
    inc(Index,L);
    for i := 1 to (Len and 7) do begin // xor 0..7 remaining bytes
      p^ := p^ xor SQLEncryptTable^[Index];
      inc(p); inc(Index);
    end;
    Dec(Count,Len);
  until Count=0;
end;


{$ifndef NOSQLITE3ENCRYPT}

procedure ChangeSQLEncryptTablePassWord(const FileName: TFileName;
  const OldPassWord, NewPassword: RawUTF8);
var F: THandle;
    R: integer;
    Buf: array[word] of byte; // temp buffer for read/write (64KB is enough)
    Size, Posi: Int64Rec;
    OldP, NewP: array[0..SQLEncryptTableSize-1] of byte; // 2x16KB tables
begin
  if OldPassword=NewPassword then
    exit;
  F := FileOpen(FileName,fmOpenReadWrite);
  if F=INVALID_HANDLE_VALUE then
    exit;
  {$ifdef MSWINDOWS}
  Size.Lo := GetFileSize(F,@Size.Hi);
  {$else}
  Int64(Size) := GetLargeFileSize(FileName);
  {$endif}
  if (Size.Lo<=1024) and (Size.Hi=0) then begin
    FileClose(F); // file is to small to be modified
    exit;
  end;
  if OldPassword<>'' then
    CreateSQLEncryptTableBytes(OldPassWord,@OldP);
  if NewPassword<>'' then
    CreateSQLEncryptTableBytes(NewPassWord,@NewP);
  Int64(Posi) := 1024; // don't change first page, which is uncrypted
  FileSeek(F,1024,soFromBeginning);
  while Int64(Posi)<Int64(Size) do begin
    R := FileRead(F,Buf,sizeof(Buf)); // read buffer
    if R<0 then
      break; // stop on any read error
    if OldPassword<>'' then
      XorOffset(@Buf,Posi.Lo,R,@OldP); // uncrypt with old key
    if NewPassword<>'' then
      XorOffset(@Buf,Posi.Lo,R,@NewP); // crypt with new key
    FileSeek64(F,Int64(Posi),soFromBeginning);
    FileWrite(F,Buf,R); // update buffer
    inc(Int64(Posi),cardinal(R));
  end;
  FileClose(F);
end;

{$endif}

// we override default WinRead() and WinWrite() functions below, in order
// to add our proprietary (but efficient) encryption engine
// - should be modified to match other Operating Systems than Windows
// - code is private to SynSQLite3Static, since it shall follow the same
// exact SQlite3.c revision compiled within the linked .obj

type
{$ifndef DELPHI5OROLDER} // Delphi 5 is already aligning records by 4 bytes
{$ifdef FPC}
{$PACKRECORDS C}
{$else}
{$A4} // bcc32 default alignment is 4 bytes
{$endif}
{$endif}

  {$ifdef MSWINDOWS}
  TSQLFile = packed record // see struct winFile in 3.8.7 sqlite3.c
    pMethods: pointer;     // sqlite3.io_methods_ptr
    pVfs: pointer;         // The VFS used to open this file (new in version 3.7)
    h: THandle;            // Handle for accessing the file
    bulk1: cardinal;       // lockType+sharedLockByte are word-aligned
    bulk2: cardinal;       // ctrlFlags (with DWORD alignment)
    lastErrno: cardinal;   // The Windows errno from the last I/O error
    // asm code generated from c is [esi+20] for lastErrNo -> OK
    pShm: pointer; // not there if SQLITE_OMIT_WAL is defined
    zPath: PAnsiChar;
    szChunk, nFetchOut: integer;
    hMap: THANDLE;
    pMapRegion: PAnsiChar;
    mmapSize, mmapSizeActual, mmapSizeMax: Int64Rec;
  end;
  {$else}
  TSQLFile = record             // see struct unixFile in 3.8.7 sqlite3.c
    pMethods: pointer;          // sqlite3.io_methods_ptr
    pVfs: pointer;              // The VFS used to open this file (new in version 3.7)
    unixInodeInfo: pointer;     // Info about locks on this inode
    h: THandle;                 // Handle for accessing the file
    eFileLock: cuchar;          // The type of lock held on this fd
    ctrlFlags: cushort;         // Behavioral bits.  UNIXFILE_* flags
    lastErrno: cint;            // The unix errno from the last I/O error
    lockingContext : PAnsiChar; // Locking style specific state
    UnixUnusedFd : pointer;     // unused
    zPath: PAnsiChar;           // Name of the file
    pShm: pointer; // not there if SQLITE_OMIT_WAL is defined
    szChunk, nFetchOut: cint;
    mmapSize, mmapSizeActual, mmapSizeMax: Int64Rec;
    pMapRegion: PAnsiChar;
  end;
  {$endif}

  // those structures are used to retrieve the Windows/Linux file handle
  TSQLPager = record            // see struct Pager in 3.8.7 sqlite3.c
    pVfs: pointer;
    exclusiveMode, journalMode, useJournal, noSync, fullSync,
    ckptSyncFlags, walsyncFlags, syncFlags, tempFile, noLock, readOnly, memDb,
    eState, eLock, changeCountDone, setMaster, doNotSpill, subjInMemory: Byte;
    dbSize, dbOrigSize, dbFileSize, dbHintSize, errCode, nRec, cksumInit,
    nSubRec: cardinal;
    pInJournal: pointer;
    fd: ^TSQLFile;   // File descriptor for database
    jfd: ^TSQLFile;  // File descriptor for main journal
    sjfd: ^TSQLFile; // File descriptor for sub-journal
  end;
  TSQLBtShared = record
    pPager: ^TSQLPager;
  end;
  TSQLBTree = record
    db: TSQLite3DB;
    pBt: ^TSQLBtShared;
  end;
  PSQLBTree = ^TSQLBTree;
  TSQLDBOneStruct = record
    zName: PAnsiChar;
    Btree: PSQLBTree;
  end;
  // will map TSQLite3DB
  PSQLDBStruct = ^TSQLDBStruct;
  TSQLDBStruct = record
    pVfs, pVdbe, pDfltColl, mutex: pointer;
    DB0: ^TSQLDBOneStruct;
    nDb: integer;  // Number of backends currently in use
  end;
{$A+}
  // used to store all currently per-database encryption tables
  TSQLCypher = record
    Handle: THandle;
    CypherBuf: RawByteString;
  end;
  TSQLCypherDynArray = array of TSQLCypher;

var
  Cyphers: TSQLCypherDynArray;
  CypherCount: integer;
  Cypher: TDynArray;

function sqlite3_key(DB: TSQLite3DB; key: pointer; keyLen: Integer): integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
var Cyph: TSQLCypher;
    pass, buf: RawByteString;
begin
  result := SQLITE_OK;
  if (DB=0) or (key=nil) or (keyLen<=0) then
    exit;
  SetString(pass,PAnsiChar(key),keyLen);
  SetLength(buf,SQLEncryptTableSize);
  CreateSQLEncryptTableBytes(pass,pointer(buf));
  Cyph.Handle := PSQLDBStruct(DB)^.DB0^.Btree^.pBt^.pPager^.fd^.h;
  if Cyphers=nil then begin
    Cypher.Init(TypeInfo(TSQLCypherDynArray),Cyphers,@CypherCount);
    Cypher.Compare := SortDynArrayPointer;
  end;
  if Cypher.Find(Cyph.Handle)>=0 then
    raise ESQLite3Exception.Create('Invalid call to sqlite3_key() with no previous sqlite3_close()');
  Cyph.CypherBuf := buf;
  Cypher.Add(Cyph);
end;

function sqlite3_rekey(DB: TSQLite3DB; key: pointer; keyLen: Integer): integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
begin
  raise ESQLite3Exception.Create('sqlite3_rekey() not implemented yet');
end;

function sqlite3_close(DB: TSQLite3DB): integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;

function sqlite3_closeInternal(DB: TSQLite3DB): integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
var i: integer;
begin
  if Cyphers<>nil then
    i := Cypher.Find(PSQLDBStruct(DB)^.DB0^.Btree^.pBt^.pPager^.fd^.h) else
    i := -1;
  result := sqlite3_close(DB);
  if i>=0 then
    Cypher.Delete(i); // do it after file closing
end;

// note that we do not use OVERLAPPED (as introduced by 3.7.12) here yet
{$ifdef MSWINDOWS}
function WinWrite(var F: TSQLFile; buf: PByte; buflen: cardinal; off: Int64): integer;
{$else}
function unixWrite(var F: TSQLFile; buf: PByte; buflen: cint; off: Int64): integer;
{$endif}
  {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
  {$ifdef FPC}
    {$ifdef MSWINDOWS}
    alias : '_winWrite';
    {$else}
    alias : 'unixWrite'; export;
    {$endif}
  {$endif}
// Write data from a buffer into a file.  Return SQLITE_OK on success
// or some other error code on failure
var n, i: integer;
    EncryptTable: PByteArray;
    offset: Int64Rec absolute off;
    nCopy: cardinal;
    b: PByte;
label err;
begin
  if off<Int64(F.mmapSize) then // handle memory mapping (SQLite3>=3.7.17)
    if CypherCount=0 then
      if off+buflen<=Int64(F.mmapSize) then begin
        Move(buf^,F.pMapRegion[offset.Lo],bufLen);
        result := SQLITE_OK;
        exit;
      end else begin
        nCopy := F.mmapSize.Lo-offset.Lo;
        Move(buf^,F.pMapRegion[offset.Lo],nCopy);
        inc(buf,nCopy);
        dec(buflen,nCopy);
        inc(off,nCopy);
      end else
      raise ESynException.Create('sqlite3_key() expects PRAGMA mmap_size=0');
  //SynSQLite3Log.Add.Log(sllCustom2,'WinWrite % off=% len=%',[F.h,off,buflen]);
  offset.Hi := offset.Hi and $7fffffff; // offset must be positive (u64)
  if FileSeek64(F.h,Int64(offset),soFromBeginning)=-1 then begin
    result := GetLastError;
    if result<>NO_ERROR then begin
      F.lastErrno := result;
      result := SQLITE_FULL;
      exit;
    end;
  end;
  EncryptTable := nil; // mark no encryption
  if CypherCount>0 then
    if (offset.Lo>=1024) or (offset.Hi<>0) then // crypt content after first page
    for i := 0 to CypherCount-1 do // (a bit) faster than Cypher.Find(F.h)
      if Cyphers[i].Handle=F.h then begin
        EncryptTable := Pointer(Cyphers[i].CypherBuf);
        XorOffset(buf,offset.Lo,buflen,EncryptTable);
        break;
      end;
  b := buf;
  n := buflen;
  result := 0;
  while n>0 do begin
    result := FileWrite(F.h,b^,n);
    if result=-1 then begin
err:  F.lastErrno := GetLastError;
      result := SQLITE_FULL;
      if EncryptTable<>nil then // restore buf content
        XorOffset(buf,offset.Lo,buflen,EncryptTable);
      exit;
    end;
    if result=0 then break;
    dec(n,result);
    inc(b,result);
  end;
  if n>result then
    goto err;
  result := SQLITE_OK;
  if EncryptTable<>nil then // restore buf content
    XorOffset(buf,offset.Lo,buflen,EncryptTable);
end;


const
  SQLITE_IOERR_READ       = $010A;
  SQLITE_IOERR_SHORT_READ = $020A;

{$ifdef MSWINDOWS}
function WinRead(var F: TSQLFile; buf: PByte; buflen: Cardinal; off: Int64): integer;
{$else}
function unixRead(var F: TSQLFile; buf: PByte; buflen: cint; off: Int64): integer;
{$endif}
  {$ifndef SQLITE3_FASTCALL}cdecl;{$endif}
  {$ifdef FPC}
    {$ifdef MSWINDOWS}
      alias : '_winRead';
    {$else}
      alias : 'unixRead'; export;
    {$endif}
  {$endif}
// Read data from a file into a buffer.  Return SQLITE_OK on success
// or some other error code on failure
var offset: Int64Rec absolute off;
    nCopy: cardinal;
    i: integer;
begin
  if off<Int64(F.mmapSize) then // handle memory mapping (SQLite3>=3.7.17)
    if CypherCount=0 then
      if off+buflen<=Int64(F.mmapSize) then begin
        Move(F.pMapRegion[offset.Lo],buf^,bufLen);
        result := SQLITE_OK;
        exit;
      end else begin
        nCopy := F.mmapSize.Lo-offset.Lo;
        Move(F.pMapRegion[offset.Lo],buf^,nCopy);
        inc(buf,nCopy);
        dec(buflen,nCopy);
        inc(off,nCopy);
      end else
      raise ESynException.Create('sqlite3_key() expects PRAGMA mmap_size=0');
  //SynSQLite3Log.Add.Log(sllCustom2,'WinRead % off=% len=%',[F.h,off,buflen]);
  offset.Hi := offset.Hi and $7fffffff; // offset must be positive (u64)
  if FileSeek64(F.h,Int64(offset),soFromBeginning)=-1 then begin
    result := GetLastError;
    if result<>NO_ERROR then begin
      F.lastErrno := result;
      result := SQLITE_FULL;
      exit;
    end;
  end;
  result := FileRead(F.h,buf^,buflen);
  if result=-1 then begin
    F.lastErrno := GetLastError;
    result := SQLITE_IOERR_READ;
    exit;
  end;
  if CypherCount>0 then
  if (offset.Lo>=1024) or (offset.Hi<>0) then // uncrypt after first page
    for i := 0 to CypherCount-1 do // (a bit) faster than Cypher.Find(F.h)
      if Cyphers[i].Handle=F.h then begin
        XorOffset(buf,offset.Lo,result,pointer(Cyphers[i].CypherBuf));
        break;
      end;
  dec(buflen,result);
  if buflen>0 then begin // remaining bytes are set to 0
    inc(buf,result);
    fillchar(buf^,buflen,0);
    result := SQLITE_IOERR_SHORT_READ;
  end else
    result := SQLITE_OK;
end;


function sqlite3_initialize: integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_shutdown: integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_open(filename: PUTF8Char; var DB: TSQLite3DB): integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_open_v2(filename: PUTF8Char; var DB: TSQLite3DB; flags: Integer; vfs: PUTF8Char): integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_create_function(DB: TSQLite3DB; FunctionName: PUTF8Char;
  nArg, eTextRep: integer; pApp: pointer; xFunc, xStep: TSQLFunctionFunc;
  xFinal: TSQLFunctionFinal): Integer;
  {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_create_function_v2(DB: TSQLite3DB; FunctionName: PUTF8Char;
  nArg, eTextRep: integer; pApp: pointer; xFunc, xStep: TSQLFunctionFunc;
  xFinal: TSQLFunctionFinal; xDestroy: TSQLDestroyPtr): Integer;
  {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_create_collation(DB: TSQLite3DB; CollationName: PUTF8Char;
  StringEncoding: integer; CollateParam: pointer; cmp: TSQLCollateFunc): integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_libversion: PUTF8Char; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_errmsg(DB: TSQLite3DB): PAnsiChar; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_extended_errcode(DB: TSQLite3DB): integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_last_insert_rowid(DB: TSQLite3DB): Int64; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_busy_timeout(DB: TSQLite3DB; Milliseconds: integer): integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_busy_handler(DB: TSQLite3DB;
  CallbackPtr: TSQLBusyHandler; user: Pointer): integer;  {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_prepare_v2(DB: TSQLite3DB; SQL: PUTF8Char; SQL_bytes: integer;
  var S: TSQLite3Statement; var SQLtail: PUTF8Char): integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_finalize(S: TSQLite3Statement): integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_next_stmt(DB: TSQLite3DB; S: TSQLite3Statement): TSQLite3Statement; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_reset(S: TSQLite3Statement): integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_stmt_readonly(S: TSQLite3Statement): boolean; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_step(S: TSQLite3Statement): integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_column_count(S: TSQLite3Statement): integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_column_type(S: TSQLite3Statement; Col: integer): integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_column_decltype(S: TSQLite3Statement; Col: integer): PAnsiChar; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_column_name(S: TSQLite3Statement; Col: integer): PUTF8Char; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_column_bytes(S: TSQLite3Statement; Col: integer): integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_column_value(S: TSQLite3Statement; Col: integer): TSQLite3Value; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_column_double(S: TSQLite3Statement; Col: integer): double; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_column_int(S: TSQLite3Statement; Col: integer): integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_column_int64(S: TSQLite3Statement; Col: integer): int64; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_column_text(S: TSQLite3Statement; Col: integer): PUTF8Char; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_column_text16(S: TSQLite3Statement; Col: integer): PWideChar; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_column_blob(S: TSQLite3Statement; Col: integer): PAnsiChar; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_value_type(Value: TSQLite3Value): integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_value_numeric_type(Value: TSQLite3Value): integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_value_bytes(Value: TSQLite3Value): integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_value_double(Value: TSQLite3Value): double; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_value_int64(Value: TSQLite3Value): Int64; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_value_text(Value: TSQLite3Value): PUTF8Char; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_value_blob(Value: TSQLite3Value): pointer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
procedure sqlite3_result_null(Context: TSQLite3FunctionContext); {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
procedure sqlite3_result_int64(Context: TSQLite3FunctionContext; Value: Int64); {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
procedure sqlite3_result_double(Context: TSQLite3FunctionContext; Value: double); {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
procedure sqlite3_result_blob(Context: TSQLite3FunctionContext; Value: Pointer;
  Value_bytes: Integer=0; DestroyPtr: TSQLDestroyPtr=SQLITE_TRANSIENT); {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
procedure sqlite3_result_text(Context: TSQLite3FunctionContext; Value: PUTF8Char;
  Value_bytes: Integer=-1; DestroyPtr: TSQLDestroyPtr=SQLITE_TRANSIENT); {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
procedure sqlite3_result_value(Context: TSQLite3FunctionContext; Value: TSQLite3Value); {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
procedure sqlite3_result_error(Context: TSQLite3FunctionContext; Msg: PUTF8Char; MsgLen: integer=-1); {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_user_data(Context: TSQLite3FunctionContext): pointer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_context_db_handle(Context: TSQLite3FunctionContext): TSQLite3DB; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_aggregate_context(Context: TSQLite3FunctionContext;
   nBytes: integer): pointer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_bind_text(S: TSQLite3Statement; Param: integer;
  Text: PUTF8Char; Text_bytes: integer=-1; DestroyPtr: TSQLDestroyPtr=SQLITE_TRANSIENT): integer;
  {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_bind_blob(S: TSQLite3Statement; Param: integer; Buf: pointer; Buf_bytes: integer;
  DestroyPtr: TSQLDestroyPtr=SQLITE_TRANSIENT): integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_bind_zeroblob(S: TSQLite3Statement; Param: integer; Size: integer): integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_bind_double(S: TSQLite3Statement; Param: integer; Value: double): integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_bind_int(S: TSQLite3Statement; Param: integer; Value: integer): integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_bind_int64(S: TSQLite3Statement; Param: integer; Value: Int64): integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_bind_null(S: TSQLite3Statement; Param: integer): integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_clear_bindings(S: TSQLite3Statement): integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_bind_parameter_count(S: TSQLite3Statement): integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_blob_open(DB: TSQLite3DB; DBName, TableName, ColumnName: PUTF8Char;
  RowID: Int64; Flags: Integer; var Blob: TSQLite3Blob): Integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_blob_close(Blob: TSQLite3Blob): Integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_blob_read(Blob: TSQLite3Blob; const Data; Count, Offset: Integer): Integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_blob_write(Blob: TSQLite3Blob; const Data; Count, Offset: Integer): Integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_blob_bytes(Blob: TSQLite3Blob): Integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_create_module_v2(DB: TSQLite3DB; const zName: PAnsiChar;
  var p: TSQLite3Module; pClientData: Pointer; xDestroy: TSQLDestroyPtr): Integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_declare_vtab(DB: TSQLite3DB; const zSQL: PAnsiChar): Integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_set_authorizer(DB: TSQLite3DB; xAuth: TSQLAuthorizerCallback;
  pUserData: Pointer): Integer;   {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_update_hook(DB: TSQLite3DB; xCallback: TSQLUpdateCallback;
  pArg: pointer): pointer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_commit_hook(DB: TSQLite3DB; xCallback: TSQLCommitCallback;
  pArg: Pointer): Pointer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_rollback_hook(DB: TSQLite3DB;  xCallback: TSQLCommitCallback;
  pArg: Pointer): Pointer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_changes(DB: TSQLite3DB): Integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_total_changes(DB: TSQLite3DB): Integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_malloc(n: Integer): Pointer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_realloc(pOld: Pointer; n: Integer): Pointer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
procedure sqlite3_free(p: Pointer); {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_memory_used: Int64; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_memory_highwater(resetFlag: Integer): Int64; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_limit(DB: TSQLite3DB; id,newValue: integer): integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_backup_init(DestDB: TSQLite3DB; DestDatabaseName: PUTF8Char;
  SourceDB: TSQLite3DB; SourceDatabaseName: PUTF8Char): TSQLite3Backup; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_backup_step(Backup: TSQLite3Backup; nPages: integer): integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_backup_finish(Backup: TSQLite3Backup): integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_backup_remaining(Backup: TSQLite3Backup): integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_backup_pagecount(Backup: TSQLite3Backup): integer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
{$ifndef DELPHI5OROLDER}
function sqlite3_config(operation: integer): integer; cdecl varargs; external;
{$endif}
{$ifdef INCLUDE_TRACE}
function sqlite3_trace(DB: TSQLite3DB; Callback: TSQLTraceCallback;
  UserData: Pointer): Pointer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
function sqlite3_profile(DB: TSQLite3DB; Callback: TSQLProfileCallback;
  UserData: Pointer): Pointer; {$ifndef SQLITE3_FASTCALL}cdecl;{$endif} external;
{$endif INCLUDE_TRACE}


{ TSQLite3LibraryStatic }

constructor TSQLite3LibraryStatic.Create;
begin
  inherited;
  initialize           := @sqlite3_initialize;
  shutdown             := @sqlite3_shutdown;
  open                 := @sqlite3_open;
  open_v2              := @sqlite3_open_v2;
  key                  := @sqlite3_key;
  rekey                := @sqlite3_rekey;
  close                := @sqlite3_closeInternal;
  libversion           := @sqlite3_libversion;
  errmsg               := @sqlite3_errmsg;
  extended_errcode     := @sqlite3_extended_errcode;
  create_function      := @sqlite3_create_function;
  create_function_v2   := @sqlite3_create_function_v2;
  create_collation     := @sqlite3_create_collation;
  last_insert_rowid    := @sqlite3_last_insert_rowid;
  busy_timeout         := @sqlite3_busy_timeout;
  busy_handler         := @sqlite3_busy_handler;
  prepare_v2           := @sqlite3_prepare_v2;
  finalize             := @sqlite3_finalize;
  next_stmt            := @sqlite3_next_stmt;
  reset                := @sqlite3_reset;
  stmt_readonly        := @sqlite3_stmt_readonly;
  step                 := @sqlite3_step;
  column_count         := @sqlite3_column_count;
  column_type          := @sqlite3_column_type;
  column_decltype      := @sqlite3_column_decltype;
  column_name          := @sqlite3_column_name;
  column_bytes         := @sqlite3_column_bytes;
  column_value         := @sqlite3_column_value;
  column_double        := @sqlite3_column_double;
  column_int           := @sqlite3_column_int;
  column_int64         := @sqlite3_column_int64;
  column_text          := @sqlite3_column_text;
  column_text16        := @sqlite3_column_text16;
  column_blob          := @sqlite3_column_blob;
  value_type           := @sqlite3_value_type;
  value_numeric_type   := @sqlite3_value_numeric_type;
  value_bytes          := @sqlite3_value_bytes;
  value_double         := @sqlite3_value_double;
  value_int64          := @sqlite3_value_int64;
  value_text           := @sqlite3_value_text;
  value_blob           := @sqlite3_value_blob;
  result_null          := @sqlite3_result_null;
  result_int64         := @sqlite3_result_int64;
  result_double        := @sqlite3_result_double;
  result_blob          := @sqlite3_result_blob;
  result_text          := @sqlite3_result_text;
  result_value         := @sqlite3_result_value;
  result_error         := @sqlite3_result_error;
  user_data            := @sqlite3_user_data;
  context_db_handle    := @sqlite3_context_db_handle;
  aggregate_context    := @sqlite3_aggregate_context;
  bind_text            := @sqlite3_bind_text;
  bind_blob            := @sqlite3_bind_blob;
  bind_zeroblob        := @sqlite3_bind_zeroblob;
  bind_double          := @sqlite3_bind_double;
  bind_int             := @sqlite3_bind_int;
  bind_int64           := @sqlite3_bind_int64;
  bind_null            := @sqlite3_bind_null;
  clear_bindings       := @sqlite3_clear_bindings;
  bind_parameter_count := @sqlite3_bind_parameter_count;
  blob_open            := @sqlite3_blob_open;
  blob_close           := @sqlite3_blob_close;
  blob_read            := @sqlite3_blob_read;
  blob_write           := @sqlite3_blob_write;
  blob_bytes           := @sqlite3_blob_bytes;
  create_module_v2     := @sqlite3_create_module_v2;
  declare_vtab         := @sqlite3_declare_vtab;
  set_authorizer       := @sqlite3_set_authorizer;
  update_hook          := @sqlite3_update_hook;
  commit_hook          := @sqlite3_commit_hook;
  rollback_hook        := @sqlite3_rollback_hook;
  changes              := @sqlite3_changes;
  total_changes        := @sqlite3_total_changes;
  malloc               := @sqlite3_malloc;
  realloc              := @sqlite3_realloc;
  free_                := @sqlite3_free;
  memory_used          := @sqlite3_memory_used;
  memory_highwater     := @sqlite3_memory_highwater;
{$ifdef INCLUDE_TRACE}
  trace                := @sqlite3_trace;
  profile              := @sqlite3_profile;
{$endif}
  limit                := @sqlite3_limit;
  backup_init          := @sqlite3_backup_init;
  backup_step          := @sqlite3_backup_step;
  backup_finish        := @sqlite3_backup_finish;
  backup_remaining     := @sqlite3_backup_remaining;
  backup_pagecount     := @sqlite3_backup_pagecount;
  {$ifndef DELPHI5OROLDER}
  config               := @sqlite3_config;
  {$endif}

  // sqlite3.obj is compiled with SQLITE_OMIT_AUTOINIT defined
  {$ifdef FPC}
  ForceToUseSharedMemoryManager; // before sqlite3_initialize otherwise SQLITE_MISUSE
  {$else}
  fUseInternalMM := true; // Delphi .obj are using FastMM4
  {$endif}
  sqlite3_initialize;
end;

destructor TSQLite3LibraryStatic.Destroy;
begin
  if Assigned(shutdown) then
    shutdown;
  inherited;
end;

initialization
  FreeAndNil(sqlite3);
  sqlite3 := TSQLite3LibraryStatic.Create;
{$endif NOSQLITE3STATIC}

end.