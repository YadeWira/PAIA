{ What the command says about itself and the machine: its version and
  commit, the compilers, the target, the system, the processor, and the
  path the model takes (--version, report, bench, selftest), and --cpu,
  which chooses that path. From PJA's pjasysinfo (the same family, author
  and licence).

  The paths: GIF's pixel model exists in Pascal and, in the release
  build, in C (paiapix.c). Both give the same bits (selftest checks it);
  only the speed changes. Which one runs is paiamodel's UseCModel: the C
  one where it is linked in, unless --cpu=pascal. }
unit paiasysinfo;

{$I paia.inc}
{$ifopt R-}{$fatal paiasysinfo: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal paiasysinfo: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, paiainfo;

type
  TCpuPath = (cpPascal, cpC);

const
  PAIA_VERSION = '0.1.0';
  CPU_PATH_NAMES: array[TCpuPath] of string = ('pascal', 'c');
  ISSUES_URL = 'https://github.com/YadeWira/PAIA/issues';

var
  { set by the program, which is compiled every time: a unit's .ppu would
    keep an old commit }
  BuildCommit: string = '';
  BuildDate: string = '';

function ParseCpuPath(const s: string; out p: TCpuPath): Boolean;
{ this build has it: pascal always, c where the C model is linked in }
function CpuPathSupported(p: TCpuPath): Boolean;
{ the paths CpuPathSupported says yes to, by name: "pascal c" }
function SupportedPaths: string;
function CurrentCpuPath: TCpuPath;
{ False, and nothing changed, for a path this build lacks. Only while no
  file is being worked on. }
function SetCpuPath(p: TCpuPath): Boolean;

{ "x86_64-linux" }
function TargetName: string;
function FpcVersion: string;
function CCompiler: string;
{ the processor's name, as it gives it ('' when it does not) }
function CpuName: string;
{ the system, as it names itself: "Linux 6.12.1 x86_64", "Windows 10.0 build 19045" }
function SystemName: string;
{ the processors this process may use, and the threads by default }
function DefaultThreads: Integer;

{ everything above, as fields of n }
procedure DescribeSystem(n: TInfoNode);
{ one block of text, "name: value" a line, for --version, report and bench;
  withVersion: the first line PAIA's version }
function SystemText(withVersion: Boolean): string;

implementation

uses
  {$ifdef UNIX} BaseUnix, {$endif}
  {$ifdef MSWINDOWS} Windows, {$endif}
  Classes, paiacpu, paiamodel;

{$ifdef CPUX86_64}
{$asmmode intel}
procedure CpuId(leaf, sub: LongWord; out a, b, c, d: LongWord);
var ra, rb, rc, rd: LongWord;
begin
  asm
    push rbx
    mov eax, leaf
    mov ecx, sub
    cpuid
    mov ra, eax
    mov rb, ebx
    mov rc, ecx
    mov rd, edx
    pop rbx
  end ['rax', 'rcx', 'rdx'];
  a := ra; b := rb; c := rc; d := rd;
end;
{$endif}
{$ifdef CPUI386}
{$asmmode intel}
procedure CpuId(leaf, sub: LongWord; out a, b, c, d: LongWord);
var ra, rb, rc, rd: LongWord;
begin
  asm
    push ebx
    mov eax, leaf
    mov ecx, sub
    cpuid
    mov ra, eax
    mov rb, ebx
    mov rc, ecx
    mov rd, edx
    pop ebx
  end ['eax', 'ecx', 'edx'];
  a := ra; b := rb; c := rc; d := rd;
end;
{$endif}

function CpuName: string;
{$if defined(CPUX86_64) or defined(CPUI386)} var b, c, d, top: LongWord; leaf: LongWord; i: Integer; regs: array[0..3] of LongWord;
                   raw: array[0..47] of Char; {$endif}
{$ifdef LINUX} var f: TStringList; k: Integer; {$endif}
begin
  Result := '';
  {$if defined(CPUX86_64) or defined(CPUI386)}
  CpuId($80000000, 0, top, b, c, d);
  if top >= $80000004 then begin
    for leaf := $80000002 to $80000004 do begin
      CpuId(leaf, 0, regs[0], regs[1], regs[2], regs[3]);
      for i := 0 to 3 do Move(regs[i], raw[(leaf - $80000002) * 16 + i * 4], 4);
    end;
    for i := 0 to 47 do
      if raw[i] = #0 then Break
      else if raw[i] in [#32..#126] then Result := Result + raw[i];
    Result := Trim(Result);
  end;
  {$endif}
  {$ifdef LINUX}
  if Result = '' then begin
    f := TStringList.Create;
    try
      try
        f.LoadFromFile('/proc/cpuinfo');
        for k := 0 to f.Count - 1 do
          if (Pos('model name', f[k]) = 1) or (Pos('Model', f[k]) = 1) or (Pos('Hardware', f[k]) = 1) then begin
            Result := Trim(Copy(f[k], Pos(':', f[k]) + 1, MaxInt));
            if Result <> '' then Break;
          end;
      except
        Result := '';
      end;
    finally
      f.Free;
    end;
  end;
  {$endif}
end;

function ParseCpuPath(const s: string; out p: TCpuPath): Boolean;
var q: TCpuPath;
begin
  for q := Low(TCpuPath) to High(TCpuPath) do
    if LowerCase(s) = CPU_PATH_NAMES[q] then begin p := q; Exit(True); end;
  p := cpPascal;
  Result := False;
end;

function CpuPathSupported(p: TCpuPath): Boolean;
begin
  if p = cpC then Result := UsingC else Result := True;
end;

function SupportedPaths: string;
var p: TCpuPath;
begin
  Result := '';
  for p := Low(TCpuPath) to High(TCpuPath) do
    if CpuPathSupported(p) then begin
      if Result <> '' then Result := Result + ' ';
      Result := Result + CPU_PATH_NAMES[p];
    end;
end;

function CurrentCpuPath: TCpuPath;
begin
  if UsingC and UseCModel then Result := cpC else Result := cpPascal;
end;

function SetCpuPath(p: TCpuPath): Boolean;
begin
  if not CpuPathSupported(p) then Exit(False);
  UseCModel := p = cpC;
  Result := True;
end;

function TargetName: string;
begin
  Result := LowerCase({$I %FPCTARGETCPU%} + '-' + {$I %FPCTARGETOS%});
end;

function FpcVersion: string;
begin
  Result := {$I %FPCVERSION%};
end;

{ the C compiler that built the C model, as it names itself (paiapix.c) }
function CCompiler: string;
begin
  if not UsingC then Exit('none (no C in this build)');
  Result := CCompilerName;
end;

{$ifdef MSWINDOWS}
type
  TRtlGetVersion = function(var v: TOSVersionInfoW): LongInt; stdcall;
{$endif}

function SystemName: string;
{$ifdef UNIX} var u: UtsName; {$endif}
{$ifdef MSWINDOWS} var v: TOSVersionInfoA; w: TOSVersionInfoW; get: TRtlGetVersion; {$endif}
begin
  Result := '';
  {$ifdef UNIX}
  if fpUname(u) = 0 then
    Result := StrPas(PChar(@u.sysname[0])) + ' ' + StrPas(PChar(@u.release[0])) + ' ' + StrPas(PChar(@u.machine[0]));
  {$endif}
  {$ifdef MSWINDOWS}
  FillChar(v, SizeOf(v), 0);
  v.dwOSVersionInfoSize := SizeOf(v);
  FillChar(w, SizeOf(w), 0);
  w.dwOSVersionInfoSize := SizeOf(w);
  { GetVersionEx says 6.2 on any Windows past 8 to a program without a
    manifest: ntdll's RtlGetVersion tells the truth (on XP too) }
  get := TRtlGetVersion(GetProcAddress(GetModuleHandle('ntdll.dll'), 'RtlGetVersion'));
  if (@get <> nil) and (get(w) = 0) then begin
    v.dwMajorVersion := w.dwMajorVersion; v.dwMinorVersion := w.dwMinorVersion; v.dwBuildNumber := w.dwBuildNumber;
  end;
  if (w.dwMajorVersion <> 0) or GetVersionExA(@v) then
    Result := 'Windows ' + IntToStr(v.dwMajorVersion) + '.' + IntToStr(v.dwMinorVersion) + ' build ' +
              IntToStr(v.dwBuildNumber)
  else Result := 'Windows';
  {$endif}
  if Result = '' then Result := {$I %FPCTARGETOS%};
end;

function DefaultThreads: Integer;
begin
  Result := CpuCount;
  if Result > 8 then Result := 8;
  if Result < 1 then Result := 1;
end;

procedure DescribeSystem(n: TInfoNode);
begin
  n.Str('paia', PAIA_VERSION);
  n.Str('commit', BuildCommit);
  n.Str('built', BuildDate);
  n.Str('fpc', FpcVersion);
  n.Str('c_compiler', CCompiler);
  n.Str('target', TargetName);
  n.Str('system', SystemName);
  n.Str('cpu', CpuName);
  n.Str('cpu_path', CPU_PATH_NAMES[CurrentCpuPath]);
  n.Str('cpu_paths_supported', SupportedPaths);
  n.Num('processors', CpuCount);
  n.Num('default_threads', DefaultThreads);
end;

function SystemText(withVersion: Boolean): string;
var n: TInfoNode; sl: TStringList; k: Integer;
begin
  Result := '';
  n := TInfoNode.Create(ikObject);
  sl := TStringList.Create;
  try
    DescribeSystem(n);
    n.Render(sl);
    for k := 0 to sl.Count - 1 do
      if withVersion or (k > 0) then Result := Result + sl[k] + LineEnding;
  finally
    sl.Free;
    n.Free;
  end;
end;

end.
