{ The models: what predicts each bit before the arithmetic coder codes it.

  TByteModel codes plain bytes (the GIF's headers, palettes, extensions, and
  the side information of each image): orders 0 to 3, mixed.

  TPixelModel codes an image's palette indices, one bit at a time from the
  top, from their neighbours in the image (left, up, and around) and in the
  previous image of the same width, the frame before in an animation.

  Both are written so that the encoder and the decoder run the very same
  code: TCoder.Code returns the bit, given on one side, decoded on the
  other. Integer only. }
unit paiamodel;

{$I paia.inc}
{$ifdef PAIA_FAST}
  {$R-}{$Q-}
{$else}
  {$ifopt R-}{$fatal paiamodel: range checks ($R+) are mandatory}{$endif}
  {$ifopt Q-}{$fatal paiamodel: overflow checks ($Q+) are mandatory}{$endif}
{$endif}

interface

uses SysUtils, paiaarith;

type
  TByteModel = class
  private
    t: array[0..3] of TCounters;
    mx: TMixer;
    apm: TApm;
    h1, h2, h3: QWord;     { the last bytes, per stream }
    c1, c2, c3: array[0..3] of Byte;
  public
    constructor Create;
    function Code(cd: TCoder; b: Integer; stream: Integer): Integer;
    { 7 bits a byte, the high bit set on all but the last }
    function CodeVarint(cd: TCoder; v: QWord; stream: Integer): QWord;
  end;

  TPixelModel = class
  private
    t: array[0..8] of TCounters;
    mx: TMixer;
    apm1, apm2: TApm;
  public
    constructor Create;
    { Codes px[0..n) (decoding: fills it), an image `width` wide, with
      `bits` bits a pixel; prev: the previous frame's pixels or nil. }
    procedure CodeImage(cd: TCoder; var px: TBytes; n: SizeInt; width, bits: Integer;
                        const prev: TBytes);
  end;

implementation

const
  TABLE_BITS = 22;

{ 32-bit mixing of a value, without overflow traps }
function Hash(a, b: QWord): QWord; inline;
begin
  Result := ((a + 1) * QWord($9E3779B1)) and $FFFFFFFF;
  Result := ((Result xor b) * QWord($85EBCA6B)) and $FFFFFFFF;
  Result := Result xor (Result shr 15);
end;

{ ---------------- bytes ---------------- }

constructor TByteModel.Create;
var i: Integer;
begin
  inherited Create;
  t[0].Init(16, 60);
  for i := 1 to 3 do t[i].Init(TABLE_BITS - 2, 60);
  mx.Init(5, 4 * 256, 6);
  apm.Init(4 * 256 * 256, 7);
  FillChar(c1, SizeOf(c1), 0); FillChar(c2, SizeOf(c2), 0); FillChar(c3, SizeOf(c3), 0);
end;

function TByteModel.Code(cd: TCoder; b: Integer; stream: Integer): Integer;
var node, bit, i, p, pm, pa: Integer; base: array[0..3] of QWord; idx: array[0..3] of SizeInt;
begin
  base[0] := QWord(stream) shl 8;
  base[1] := Hash(QWord(stream) * 256 + c1[stream], 1);
  base[2] := Hash(QWord(stream) * 65536 + QWord(c1[stream]) * 256 + c2[stream], 2);
  base[3] := Hash(Hash(QWord(c1[stream]) * 65536 + QWord(c2[stream]) * 256 + c3[stream], 3), stream);
  node := 1;
  for i := 7 downto 0 do begin
    idx[0] := (base[0] + QWord(node)) and t[0].mask;
    idx[1] := (base[1] + QWord(node) * 31) and t[1].mask;
    idx[2] := (base[2] + QWord(node) * 31) and t[2].mask;
    idx[3] := (base[3] + QWord(node) * 31) and t[3].mask;
    for p := 0 to 3 do mx.Add(Stretch(t[p].P12(idx[p])));
    mx.Add(256);
    pm := mx.Mix(stream * 256 + node);
    pa := apm.Refine(pm, (SizeInt(stream) * 256 + c1[stream]) * 256 + node);
    p := (pm + 3 * pa) div 4;
    bit := cd.Code((b shr i) and 1, p);
    for p := 0 to 3 do t[p].Update(idx[p], bit);
    mx.Update(bit);
    apm.Update(bit);
    node := node * 2 + bit;
  end;
  Result := node and 255;
  c3[stream] := c2[stream]; c2[stream] := c1[stream]; c1[stream] := Result;
end;

function TByteModel.CodeVarint(cd: TCoder; v: QWord; stream: Integer): QWord;
var b, shift: Integer;
begin
  Result := 0; shift := 0;
  repeat
    if cd.encoding then begin
      b := v and 127; v := v shr 7;
      if v <> 0 then b := b or 128;
    end else b := 0;
    b := Code(cd, b, stream);
    if shift > 63 then raise Exception.Create('paiamodel: varint too long');
    Result := Result or (QWord(b and 127) shl shift);
    shift := shift + 7;
  until (b and 128) = 0;
end;

{ ---------------- pixels ---------------- }

constructor TPixelModel.Create;
var i: Integer;
begin
  inherited Create;
  for i := 0 to High(t) do t[i].Init(TABLE_BITS, 255);
  mx.Init(Length(t) + 1, 8 * 8, 4);
  apm1.Init(256 * 256, 7);
  apm2.Init(256 * 256, 7);
end;

procedure TPixelModel.CodeImage(cd: TCoder; var px: TBytes; n: SizeInt; width, bits: Integer;
                                const prev: TBytes);
const NONE = 256;
var i: SizeInt; x, y, L, U, UL, UR, LL, UU, PV, PR, PD, v, pr12, node, bit, b, j, pm, pa, sel: Integer;
    hasPrev: Boolean; base: array[0..8] of QWord; idx: array[0..8] of SizeInt;
    w: SizeInt;
begin
  if width < 1 then width := 1;
  w := width;
  hasPrev := (prev <> nil);
  x := 0; y := 0;
  for i := 0 to n - 1 do begin
    if x > 0 then L := px[i - 1] else L := NONE;
    if x > 1 then LL := px[i - 2] else LL := NONE;
    if y > 0 then begin
      U := px[i - w];
      if x > 0 then UL := px[i - w - 1] else UL := NONE;
      if x + 1 < width then UR := px[i - w + 1] else UR := NONE;
    end else begin U := NONE; UL := NONE; UR := NONE; end;
    if y > 1 then UU := px[i - 2 * w] else UU := NONE;
    if hasPrev and (i < Length(prev)) then begin
      PV := prev[i];
      if (x + 1 < width) and (i + 1 < Length(prev)) then PR := prev[i + 1] else PR := NONE;
      if i + w < Length(prev) then PD := prev[i + w] else PD := NONE;
    end else begin PV := NONE; PR := NONE; PD := NONE; end;

    base[0] := QWord(bits) shl 12;
    base[1] := Hash(L, 1);
    base[2] := Hash(U, 2);
    base[3] := Hash(L * 512 + U, 3);
    base[4] := Hash(Hash(L * 512 + U, UL * 512 + UR), 4);
    base[5] := Hash(Hash(L * 512 + LL, U * 512 + UU), 5);
    base[6] := Hash(Hash(PV, L * 512 + U), 6);
    base[7] := Hash(Hash(PV * 512 + PR, PD), 7);
    base[8] := Hash(Hash(UL * 512 + U, UR), 8);

    sel := Ord(L = U) + 2 * Ord(hasPrev and (PV = L)) + 4 * Ord(U = UR);
    v := 0; if cd.encoding then v := px[i];
    node := 1;
    for b := bits - 1 downto 0 do begin
      for j := 0 to High(t) do begin
        if j = 0 then idx[0] := (base[0] + QWord(node)) and t[0].mask
        else idx[j] := (base[j] + QWord(node) * 4099) and t[j].mask;
        mx.Add(Stretch(t[j].P12(idx[j])));
      end;
      mx.Add(256);
      pm := mx.Mix((bits - 1 - b) * 8 + sel);
      pa := apm1.Refine(pm, ((L and 255) shl 8) or (node and 255));
      bit := apm2.Refine(pm, ((U and 255) shl 8) or (node and 255));
      pr12 := (2 * pm + pa + bit) div 4;
      bit := cd.Code((v shr b) and 1, pr12);
      for j := 0 to High(t) do t[j].Update(idx[j], bit);
      mx.Update(bit);
      apm1.Update(bit);
      apm2.Update(bit);
      node := node * 2 + bit;
    end;
    px[i] := node - (1 shl bits);
    Inc(x);
    if x = width then begin x := 0; Inc(y); end;
  end;
end;

end.
