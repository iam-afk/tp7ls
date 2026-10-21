unit tp7enc;

{$mode objfpc}{$H+}

interface

function Cp866ToUtf8(const S: RawByteString): string;
function Utf8ToCp866(const S: string): RawByteString;
function ReadFileBytes(const Path: string): RawByteString;
function ReadSource(const Path: string): string;
function Utf8Length(const S: string; First, Last: SizeInt): SizeInt;
function SpaceLen(const S: string; I: SizeInt): SizeInt;
function StripSpace(const S: string): string;
function FirstWord(const S: string): string;
function UpperText(const S: string): string;
function LowerText(const S: string): string;
function PyRepr(const S: string): string;
function CodePointOf(const S: string): LongWord;
function DecodeUtf8(const S: string; I: SizeInt; out Len: SizeInt): LongWord;
function IsWordCodePoint(C: LongWord): Boolean;
function IsWordAt(const S: string; I: SizeInt; out Len: SizeInt): Boolean;
function IsWordBefore(const S: string; I: SizeInt): Boolean;
function Utf16Length(const S: string): SizeInt;
function CharOffset(const S: string; N: SizeInt): SizeInt;
function CharCopy(const S: string; N: SizeInt): string;

implementation

uses
  Classes, SysUtils;

const
  Cp866High: array[$80..$FF] of Word = (
    $0410, $0411, $0412, $0413, $0414, $0415, $0416, $0417,
    $0418, $0419, $041A, $041B, $041C, $041D, $041E, $041F,
    $0420, $0421, $0422, $0423, $0424, $0425, $0426, $0427,
    $0428, $0429, $042A, $042B, $042C, $042D, $042E, $042F,
    $0430, $0431, $0432, $0433, $0434, $0435, $0436, $0437,
    $0438, $0439, $043A, $043B, $043C, $043D, $043E, $043F,
    $2591, $2592, $2593, $2502, $2524, $2561, $2562, $2556,
    $2555, $2563, $2551, $2557, $255D, $255C, $255B, $2510,
    $2514, $2534, $252C, $251C, $2500, $253C, $255E, $255F,
    $255A, $2554, $2569, $2566, $2560, $2550, $256C, $2567,
    $2568, $2564, $2565, $2559, $2558, $2552, $2553, $256B,
    $256A, $2518, $250C, $2588, $2584, $258C, $2590, $2580,
    $0440, $0441, $0442, $0443, $0444, $0445, $0446, $0447,
    $0448, $0449, $044A, $044B, $044C, $044D, $044E, $044F,
    $0401, $0451, $0404, $0454, $0407, $0457, $040E, $045E,
    $00B0, $2219, $00B7, $221A, $2116, $00A4, $25A0, $00A0);

  { str.isalnum() of Python 3, code points >= $80: [first, last] pairs }
  WordRanges: array[0..1533] of LongWord = (
    $AA, $AA, $B2, $B3, $B5, $B5, $B9, $BA, $BC, $BE, $C0, $D6, $D8, $F6, $F8, $2C1, $2C6, $2D1, $2E0, $2E4, $2EC,
    $2EC, $2EE, $2EE, $370, $374, $376, $377, $37A, $37D, $37F, $37F, $386, $386, $388, $38A, $38C, $38C, $38E, $3A1,
    $3A3, $3F5, $3F7, $481, $48A, $52F, $531, $556, $559, $559, $560, $588, $5D0, $5EA, $5EF, $5F2, $620, $64A, $660,
    $669, $66E, $66F, $671, $6D3, $6D5, $6D5, $6E5, $6E6, $6EE, $6FC, $6FF, $6FF, $710, $710, $712, $72F, $74D, $7A5,
    $7B1, $7B1, $7C0, $7EA, $7F4, $7F5, $7FA, $7FA, $800, $815, $81A, $81A, $824, $824, $828, $828, $840, $858, $860,
    $86A, $870, $887, $889, $88E, $8A0, $8C9, $904, $939, $93D, $93D, $950, $950, $958, $961, $966, $96F, $971, $980,
    $985, $98C, $98F, $990, $993, $9A8, $9AA, $9B0, $9B2, $9B2, $9B6, $9B9, $9BD, $9BD, $9CE, $9CE, $9DC, $9DD, $9DF,
    $9E1, $9E6, $9F1, $9F4, $9F9, $9FC, $9FC, $A05, $A0A, $A0F, $A10, $A13, $A28, $A2A, $A30, $A32, $A33, $A35, $A36,
    $A38, $A39, $A59, $A5C, $A5E, $A5E, $A66, $A6F, $A72, $A74, $A85, $A8D, $A8F, $A91, $A93, $AA8, $AAA, $AB0, $AB2,
    $AB3, $AB5, $AB9, $ABD, $ABD, $AD0, $AD0, $AE0, $AE1, $AE6, $AEF, $AF9, $AF9, $B05, $B0C, $B0F, $B10, $B13, $B28,
    $B2A, $B30, $B32, $B33, $B35, $B39, $B3D, $B3D, $B5C, $B5D, $B5F, $B61, $B66, $B6F, $B71, $B77, $B83, $B83, $B85,
    $B8A, $B8E, $B90, $B92, $B95, $B99, $B9A, $B9C, $B9C, $B9E, $B9F, $BA3, $BA4, $BA8, $BAA, $BAE, $BB9, $BD0, $BD0,
    $BE6, $BF2, $C05, $C0C, $C0E, $C10, $C12, $C28, $C2A, $C39, $C3D, $C3D, $C58, $C5A, $C5D, $C5D, $C60, $C61, $C66,
    $C6F, $C78, $C7E, $C80, $C80, $C85, $C8C, $C8E, $C90, $C92, $CA8, $CAA, $CB3, $CB5, $CB9, $CBD, $CBD, $CDD, $CDE,
    $CE0, $CE1, $CE6, $CEF, $CF1, $CF2, $D04, $D0C, $D0E, $D10, $D12, $D3A, $D3D, $D3D, $D4E, $D4E, $D54, $D56, $D58,
    $D61, $D66, $D78, $D7A, $D7F, $D85, $D96, $D9A, $DB1, $DB3, $DBB, $DBD, $DBD, $DC0, $DC6, $DE6, $DEF, $E01, $E30,
    $E32, $E33, $E40, $E46, $E50, $E59, $E81, $E82, $E84, $E84, $E86, $E8A, $E8C, $EA3, $EA5, $EA5, $EA7, $EB0, $EB2,
    $EB3, $EBD, $EBD, $EC0, $EC4, $EC6, $EC6, $ED0, $ED9, $EDC, $EDF, $F00, $F00, $F20, $F33, $F40, $F47, $F49, $F6C,
    $F88, $F8C, $1000, $102A, $103F, $1049, $1050, $1055, $105A, $105D, $1061, $1061, $1065, $1066, $106E, $1070,
    $1075, $1081, $108E, $108E, $1090, $1099, $10A0, $10C5, $10C7, $10C7, $10CD, $10CD, $10D0, $10FA, $10FC, $1248,
    $124A, $124D, $1250, $1256, $1258, $1258, $125A, $125D, $1260, $1288, $128A, $128D, $1290, $12B0, $12B2, $12B5,
    $12B8, $12BE, $12C0, $12C0, $12C2, $12C5, $12C8, $12D6, $12D8, $1310, $1312, $1315, $1318, $135A, $1369, $137C,
    $1380, $138F, $13A0, $13F5, $13F8, $13FD, $1401, $166C, $166F, $167F, $1681, $169A, $16A0, $16EA, $16EE, $16F8,
    $1700, $1711, $171F, $1731, $1740, $1751, $1760, $176C, $176E, $1770, $1780, $17B3, $17D7, $17D7, $17DC, $17DC,
    $17E0, $17E9, $17F0, $17F9, $1810, $1819, $1820, $1878, $1880, $1884, $1887, $18A8, $18AA, $18AA, $18B0, $18F5,
    $1900, $191E, $1946, $196D, $1970, $1974, $1980, $19AB, $19B0, $19C9, $19D0, $19DA, $1A00, $1A16, $1A20, $1A54,
    $1A80, $1A89, $1A90, $1A99, $1AA7, $1AA7, $1B05, $1B33, $1B45, $1B4C, $1B50, $1B59, $1B83, $1BA0, $1BAE, $1BE5,
    $1C00, $1C23, $1C40, $1C49, $1C4D, $1C7D, $1C80, $1C8A, $1C90, $1CBA, $1CBD, $1CBF, $1CE9, $1CEC, $1CEE, $1CF3,
    $1CF5, $1CF6, $1CFA, $1CFA, $1D00, $1DBF, $1E00, $1F15, $1F18, $1F1D, $1F20, $1F45, $1F48, $1F4D, $1F50, $1F57,
    $1F59, $1F59, $1F5B, $1F5B, $1F5D, $1F5D, $1F5F, $1F7D, $1F80, $1FB4, $1FB6, $1FBC, $1FBE, $1FBE, $1FC2, $1FC4,
    $1FC6, $1FCC, $1FD0, $1FD3, $1FD6, $1FDB, $1FE0, $1FEC, $1FF2, $1FF4, $1FF6, $1FFC, $2070, $2071, $2074, $2079,
    $207F, $2089, $2090, $209C, $2102, $2102, $2107, $2107, $210A, $2113, $2115, $2115, $2119, $211D, $2124, $2124,
    $2126, $2126, $2128, $2128, $212A, $212D, $212F, $2139, $213C, $213F, $2145, $2149, $214E, $214E, $2150, $2189,
    $2460, $249B, $24EA, $24FF, $2776, $2793, $2C00, $2CE4, $2CEB, $2CEE, $2CF2, $2CF3, $2CFD, $2CFD, $2D00, $2D25,
    $2D27, $2D27, $2D2D, $2D2D, $2D30, $2D67, $2D6F, $2D6F, $2D80, $2D96, $2DA0, $2DA6, $2DA8, $2DAE, $2DB0, $2DB6,
    $2DB8, $2DBE, $2DC0, $2DC6, $2DC8, $2DCE, $2DD0, $2DD6, $2DD8, $2DDE, $2E2F, $2E2F, $3005, $3007, $3021, $3029,
    $3031, $3035, $3038, $303C, $3041, $3096, $309D, $309F, $30A1, $30FA, $30FC, $30FF, $3105, $312F, $3131, $318E,
    $3192, $3195, $31A0, $31BF, $31F0, $31FF, $3220, $3229, $3248, $324F, $3251, $325F, $3280, $3289, $32B1, $32BF,
    $3400, $4DBF, $4E00, $A48C, $A4D0, $A4FD, $A500, $A60C, $A610, $A62B, $A640, $A66E, $A67F, $A69D, $A6A0, $A6EF,
    $A717, $A71F, $A722, $A788, $A78B, $A7CD, $A7D0, $A7D1, $A7D3, $A7D3, $A7D5, $A7DC, $A7F2, $A801, $A803, $A805,
    $A807, $A80A, $A80C, $A822, $A830, $A835, $A840, $A873, $A882, $A8B3, $A8D0, $A8D9, $A8F2, $A8F7, $A8FB, $A8FB,
    $A8FD, $A8FE, $A900, $A925, $A930, $A946, $A960, $A97C, $A984, $A9B2, $A9CF, $A9D9, $A9E0, $A9E4, $A9E6, $A9FE,
    $AA00, $AA28, $AA40, $AA42, $AA44, $AA4B, $AA50, $AA59, $AA60, $AA76, $AA7A, $AA7A, $AA7E, $AAAF, $AAB1, $AAB1,
    $AAB5, $AAB6, $AAB9, $AABD, $AAC0, $AAC0, $AAC2, $AAC2, $AADB, $AADD, $AAE0, $AAEA, $AAF2, $AAF4, $AB01, $AB06,
    $AB09, $AB0E, $AB11, $AB16, $AB20, $AB26, $AB28, $AB2E, $AB30, $AB5A, $AB5C, $AB69, $AB70, $ABE2, $ABF0, $ABF9,
    $AC00, $D7A3, $D7B0, $D7C6, $D7CB, $D7FB, $F900, $FA6D, $FA70, $FAD9, $FB00, $FB06, $FB13, $FB17, $FB1D, $FB1D,
    $FB1F, $FB28, $FB2A, $FB36, $FB38, $FB3C, $FB3E, $FB3E, $FB40, $FB41, $FB43, $FB44, $FB46, $FBB1, $FBD3, $FD3D,
    $FD50, $FD8F, $FD92, $FDC7, $FDF0, $FDFB, $FE70, $FE74, $FE76, $FEFC, $FF10, $FF19, $FF21, $FF3A, $FF41, $FF5A,
    $FF66, $FFBE, $FFC2, $FFC7, $FFCA, $FFCF, $FFD2, $FFD7, $FFDA, $FFDC, $10000, $1000B, $1000D, $10026, $10028,
    $1003A, $1003C, $1003D, $1003F, $1004D, $10050, $1005D, $10080, $100FA, $10107, $10133, $10140, $10178, $1018A,
    $1018B, $10280, $1029C, $102A0, $102D0, $102E1, $102FB, $10300, $10323, $1032D, $1034A, $10350, $10375, $10380,
    $1039D, $103A0, $103C3, $103C8, $103CF, $103D1, $103D5, $10400, $1049D, $104A0, $104A9, $104B0, $104D3, $104D8,
    $104FB, $10500, $10527, $10530, $10563, $10570, $1057A, $1057C, $1058A, $1058C, $10592, $10594, $10595, $10597,
    $105A1, $105A3, $105B1, $105B3, $105B9, $105BB, $105BC, $105C0, $105F3, $10600, $10736, $10740, $10755, $10760,
    $10767, $10780, $10785, $10787, $107B0, $107B2, $107BA, $10800, $10805, $10808, $10808, $1080A, $10835, $10837,
    $10838, $1083C, $1083C, $1083F, $10855, $10858, $10876, $10879, $1089E, $108A7, $108AF, $108E0, $108F2, $108F4,
    $108F5, $108FB, $1091B, $10920, $10939, $10980, $109B7, $109BC, $109CF, $109D2, $10A00, $10A10, $10A13, $10A15,
    $10A17, $10A19, $10A35, $10A40, $10A48, $10A60, $10A7E, $10A80, $10A9F, $10AC0, $10AC7, $10AC9, $10AE4, $10AEB,
    $10AEF, $10B00, $10B35, $10B40, $10B55, $10B58, $10B72, $10B78, $10B91, $10BA9, $10BAF, $10C00, $10C48, $10C80,
    $10CB2, $10CC0, $10CF2, $10CFA, $10D23, $10D30, $10D39, $10D40, $10D65, $10D6F, $10D85, $10E60, $10E7E, $10E80,
    $10EA9, $10EB0, $10EB1, $10EC2, $10EC4, $10F00, $10F27, $10F30, $10F45, $10F51, $10F54, $10F70, $10F81, $10FB0,
    $10FCB, $10FE0, $10FF6, $11003, $11037, $11052, $1106F, $11071, $11072, $11075, $11075, $11083, $110AF, $110D0,
    $110E8, $110F0, $110F9, $11103, $11126, $11136, $1113F, $11144, $11144, $11147, $11147, $11150, $11172, $11176,
    $11176, $11183, $111B2, $111C1, $111C4, $111D0, $111DA, $111DC, $111DC, $111E1, $111F4, $11200, $11211, $11213,
    $1122B, $1123F, $11240, $11280, $11286, $11288, $11288, $1128A, $1128D, $1128F, $1129D, $1129F, $112A8, $112B0,
    $112DE, $112F0, $112F9, $11305, $1130C, $1130F, $11310, $11313, $11328, $1132A, $11330, $11332, $11333, $11335,
    $11339, $1133D, $1133D, $11350, $11350, $1135D, $11361, $11380, $11389, $1138B, $1138B, $1138E, $1138E, $11390,
    $113B5, $113B7, $113B7, $113D1, $113D1, $113D3, $113D3, $11400, $11434, $11447, $1144A, $11450, $11459, $1145F,
    $11461, $11480, $114AF, $114C4, $114C5, $114C7, $114C7, $114D0, $114D9, $11580, $115AE, $115D8, $115DB, $11600,
    $1162F, $11644, $11644, $11650, $11659, $11680, $116AA, $116B8, $116B8, $116C0, $116C9, $116D0, $116E3, $11700,
    $1171A, $11730, $1173B, $11740, $11746, $11800, $1182B, $118A0, $118F2, $118FF, $11906, $11909, $11909, $1190C,
    $11913, $11915, $11916, $11918, $1192F, $1193F, $1193F, $11941, $11941, $11950, $11959, $119A0, $119A7, $119AA,
    $119D0, $119E1, $119E1, $119E3, $119E3, $11A00, $11A00, $11A0B, $11A32, $11A3A, $11A3A, $11A50, $11A50, $11A5C,
    $11A89, $11A9D, $11A9D, $11AB0, $11AF8, $11BC0, $11BE0, $11BF0, $11BF9, $11C00, $11C08, $11C0A, $11C2E, $11C40,
    $11C40, $11C50, $11C6C, $11C72, $11C8F, $11D00, $11D06, $11D08, $11D09, $11D0B, $11D30, $11D46, $11D46, $11D50,
    $11D59, $11D60, $11D65, $11D67, $11D68, $11D6A, $11D89, $11D98, $11D98, $11DA0, $11DA9, $11EE0, $11EF2, $11F02,
    $11F02, $11F04, $11F10, $11F12, $11F33, $11F50, $11F59, $11FB0, $11FB0, $11FC0, $11FD4, $12000, $12399, $12400,
    $1246E, $12480, $12543, $12F90, $12FF0, $13000, $1342F, $13441, $13446, $13460, $143FA, $14400, $14646, $16100,
    $1611D, $16130, $16139, $16800, $16A38, $16A40, $16A5E, $16A60, $16A69, $16A70, $16ABE, $16AC0, $16AC9, $16AD0,
    $16AED, $16B00, $16B2F, $16B40, $16B43, $16B50, $16B59, $16B5B, $16B61, $16B63, $16B77, $16B7D, $16B8F, $16D40,
    $16D6C, $16D70, $16D79, $16E40, $16E96, $16F00, $16F4A, $16F50, $16F50, $16F93, $16F9F, $16FE0, $16FE1, $16FE3,
    $16FE3, $17000, $187F7, $18800, $18CD5, $18CFF, $18D08, $1AFF0, $1AFF3, $1AFF5, $1AFFB, $1AFFD, $1AFFE, $1B000,
    $1B122, $1B132, $1B132, $1B150, $1B152, $1B155, $1B155, $1B164, $1B167, $1B170, $1B2FB, $1BC00, $1BC6A, $1BC70,
    $1BC7C, $1BC80, $1BC88, $1BC90, $1BC99, $1CCF0, $1CCF9, $1D2C0, $1D2D3, $1D2E0, $1D2F3, $1D360, $1D378, $1D400,
    $1D454, $1D456, $1D49C, $1D49E, $1D49F, $1D4A2, $1D4A2, $1D4A5, $1D4A6, $1D4A9, $1D4AC, $1D4AE, $1D4B9, $1D4BB,
    $1D4BB, $1D4BD, $1D4C3, $1D4C5, $1D505, $1D507, $1D50A, $1D50D, $1D514, $1D516, $1D51C, $1D51E, $1D539, $1D53B,
    $1D53E, $1D540, $1D544, $1D546, $1D546, $1D54A, $1D550, $1D552, $1D6A5, $1D6A8, $1D6C0, $1D6C2, $1D6DA, $1D6DC,
    $1D6FA, $1D6FC, $1D714, $1D716, $1D734, $1D736, $1D74E, $1D750, $1D76E, $1D770, $1D788, $1D78A, $1D7A8, $1D7AA,
    $1D7C2, $1D7C4, $1D7CB, $1D7CE, $1D7FF, $1DF00, $1DF1E, $1DF25, $1DF2A, $1E030, $1E06D, $1E100, $1E12C, $1E137,
    $1E13D, $1E140, $1E149, $1E14E, $1E14E, $1E290, $1E2AD, $1E2C0, $1E2EB, $1E2F0, $1E2F9, $1E4D0, $1E4EB, $1E4F0,
    $1E4F9, $1E5D0, $1E5ED, $1E5F0, $1E5FA, $1E7E0, $1E7E6, $1E7E8, $1E7EB, $1E7ED, $1E7EE, $1E7F0, $1E7FE, $1E800,
    $1E8C4, $1E8C7, $1E8CF, $1E900, $1E943, $1E94B, $1E94B, $1E950, $1E959, $1EC71, $1ECAB, $1ECAD, $1ECAF, $1ECB1,
    $1ECB4, $1ED01, $1ED2D, $1ED2F, $1ED3D, $1EE00, $1EE03, $1EE05, $1EE1F, $1EE21, $1EE22, $1EE24, $1EE24, $1EE27,
    $1EE27, $1EE29, $1EE32, $1EE34, $1EE37, $1EE39, $1EE39, $1EE3B, $1EE3B, $1EE42, $1EE42, $1EE47, $1EE47, $1EE49,
    $1EE49, $1EE4B, $1EE4B, $1EE4D, $1EE4F, $1EE51, $1EE52, $1EE54, $1EE54, $1EE57, $1EE57, $1EE59, $1EE59, $1EE5B,
    $1EE5B, $1EE5D, $1EE5D, $1EE5F, $1EE5F, $1EE61, $1EE62, $1EE64, $1EE64, $1EE67, $1EE6A, $1EE6C, $1EE72, $1EE74,
    $1EE77, $1EE79, $1EE7C, $1EE7E, $1EE7E, $1EE80, $1EE89, $1EE8B, $1EE9B, $1EEA1, $1EEA3, $1EEA5, $1EEA9, $1EEAB,
    $1EEBB, $1F100, $1F10C, $1FBF0, $1FBF9, $20000, $2A6DF, $2A700, $2B739, $2B740, $2B81D, $2B820, $2CEA1, $2CEB0,
    $2EBE0, $2EBF0, $2EE5D, $2F800, $2FA1D, $30000, $3134A, $31350, $323AF);

function Cp866ToUtf8(const S: RawByteString): string;
var
  I, N: SizeInt;
  C: Word;
begin
  SetLength(Result, Length(S) * 3);
  N := 0;
  for I := 1 to Length(S) do
  begin
    if Ord(S[I]) < $80 then
    begin
      Inc(N);
      Result[N] := S[I];
      Continue;
    end;
    C := Cp866High[Ord(S[I])];
    if C < $800 then
    begin
      Result[N + 1] := Chr($C0 or (C shr 6));
      Result[N + 2] := Chr($80 or (C and $3F));
      Inc(N, 2);
    end
    else
    begin
      Result[N + 1] := Chr($E0 or (C shr 12));
      Result[N + 2] := Chr($80 or ((C shr 6) and $3F));
      Result[N + 3] := Chr($80 or (C and $3F));
      Inc(N, 3);
    end;
  end;
  SetLength(Result, N);
end;

function Cp866Byte(CodePoint: LongWord): Char;
var
  B: Integer;
begin
  for B := Low(Cp866High) to High(Cp866High) do
    if Cp866High[B] = CodePoint then
      Exit(Chr(B));
  Result := '?';
end;

function Utf8ToCp866(const S: string): RawByteString;
var
  I, N, Len, K: SizeInt;
  B: Byte;
  C: LongWord;
begin
  SetLength(Result, Length(S));
  N := 0;
  I := 1;
  while I <= Length(S) do
  begin
    B := Ord(S[I]);
    if B < $80 then
    begin
      Len := 1;
      C := B;
    end
    else if B and $E0 = $C0 then
    begin
      Len := 2;
      C := B and $1F;
    end
    else if B and $F0 = $E0 then
    begin
      Len := 3;
      C := B and $0F;
    end
    else if B and $F8 = $F0 then
    begin
      Len := 4;
      C := B and $07;
    end
    else
    begin
      Len := 1;
      C := $FFFD;
    end;
    for K := 1 to Len - 1 do
      if (I + K <= Length(S)) and (Ord(S[I + K]) and $C0 = $80) then
        C := (C shl 6) or (Ord(S[I + K]) and $3F)
      else
      begin
        Len := K;
        C := $FFFD;
        Break;
      end;
    Inc(N);
    if C < $80 then
      Result[N] := Chr(C)
    else
      Result[N] := Cp866Byte(C);
    Inc(I, Len);
  end;
  SetLength(Result, N);
end;

function ReadFileBytes(const Path: string): RawByteString;
var
  F: TFileStream;
begin
  Result := '';
  F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, F.Size);
    if Length(Result) > 0 then
      F.ReadBuffer(Result[1], Length(Result));
  finally
    F.Free;
  end;
end;

function ReadSource(const Path: string): string;
begin
  Result := Cp866ToUtf8(ReadFileBytes(Path));
end;

function Utf8Length(const S: string; First, Last: SizeInt): SizeInt;
var
  I: SizeInt;
begin
  Result := 0;
  for I := First to Last do
    if Ord(S[I]) and $C0 <> $80 then
      Inc(Result);
end;

function SpaceLen(const S: string; I: SizeInt): SizeInt;

  function At(K: SizeInt): Byte;
  begin
    if I + K <= Length(S) then
      Result := Ord(S[I + K])
    else
      Result := 0;
  end;

begin
  Result := 0;
  case At(0) of
    9..13, 28..32:
      Result := 1;
    $C2:
      if At(1) in [$85, $A0] then
        Result := 2;
    $E1:
      if (At(1) = $9A) and (At(2) = $80) then
        Result := 3;
    $E2:
      if ((At(1) = $80) and (At(2) in [$80..$8A, $A8, $A9, $AF])) or ((At(1) = $81) and (At(2) = $9F)) then
        Result := 3;
    $E3:
      if (At(1) = $80) and (At(2) = $80) then
        Result := 3;
  end;
end;

function StripSpace(const S: string): string;
var
  I, First, Stop, Len: SizeInt;
begin
  I := 1;
  First := 0;
  Stop := 0;
  while I <= Length(S) do
  begin
    Len := SpaceLen(S, I);
    if Len = 0 then
    begin
      if First = 0 then
        First := I;
      Inc(I);
      while (I <= Length(S)) and (Ord(S[I]) and $C0 = $80) do
        Inc(I);
      Stop := I;
    end
    else
      Inc(I, Len);
  end;
  if First = 0 then
    Result := ''
  else
    Result := Copy(S, First, Stop - First);
end;

function FirstWord(const S: string): string;
var
  T: string;
  I: SizeInt;
begin
  T := StripSpace(S);
  I := 1;
  while (I <= Length(T)) and (SpaceLen(T, I) = 0) do
    Inc(I);
  Result := Copy(T, 1, I - 1);
end;

function UpperText(const S: string): string;
var
  I: SizeInt;
  B: Byte;
begin
  Result := S;
  UniqueString(Result);
  I := 1;
  while I <= Length(Result) do
  begin
    B := Ord(Result[I]);
    if Result[I] in ['a'..'z'] then
      Result[I] := Chr(B - 32)
    else if (I < Length(Result)) and (B = $D0) and (Ord(Result[I + 1]) in [$B0..$BF]) then
      Result[I + 1] := Chr(Ord(Result[I + 1]) - $20)
    else if (I < Length(Result)) and (B = $D1) and (Ord(Result[I + 1]) in [$80..$8F]) then
    begin
      Result[I] := Chr($D0);
      Result[I + 1] := Chr(Ord(Result[I + 1]) + $20);
    end
    else if (I < Length(Result)) and (B = $D1) and (Ord(Result[I + 1]) in [$90..$9F]) then
    begin
      Result[I] := Chr($D0);
      Result[I + 1] := Chr(Ord(Result[I + 1]) - $10);
    end;
    Inc(I);
  end;
end;

function LowerText(const S: string): string;
var
  I: SizeInt;
  B, C: Byte;
begin
  Result := S;
  UniqueString(Result);
  I := 1;
  while I <= Length(Result) do
  begin
    B := Ord(Result[I]);
    if Result[I] in ['A'..'Z'] then
      Result[I] := Chr(B + 32)
    else if (I < Length(Result)) and (B = $D0) then
    begin
      C := Ord(Result[I + 1]);
      if C in [$90..$9F] then
        Result[I + 1] := Chr(C + $20)
      else if C in [$A0..$AF] then
      begin
        Result[I] := Chr($D1);
        Result[I + 1] := Chr(C - $20);
      end
      else if C in [$80..$8F] then
      begin
        Result[I] := Chr($D1);
        Result[I + 1] := Chr(C + $10);
      end;
    end;
    Inc(I);
  end;
end;

function PyRepr(const S: string): string;
var
  Quote: Char;
  I: SizeInt;
  C: Char;
begin
  if (Pos('''', S) > 0) and (Pos('"', S) = 0) then
    Quote := '"'
  else
    Quote := '''';
  Result := Quote;
  I := 1;
  while I <= Length(S) do
  begin
    C := S[I];
    if C = '\' then
      Result := Result + '\\'
    else if C = Quote then
      Result := Result + '\' + C
    else if C = #9 then
      Result := Result + '\t'
    else if C = #10 then
      Result := Result + '\n'
    else if C = #13 then
      Result := Result + '\r'
    else if (C < ' ') or (C = #127) then
      Result := Result + '\x' + LowerCase(IntToHex(Ord(C), 2))
    else if (C = #$C2) and (I < Length(S)) and (S[I + 1] in [#$80..#$A0, #$AD]) then
    begin
      Result := Result + '\x' + LowerCase(IntToHex(Ord(S[I + 1]), 2));
      Inc(I);
    end
    else
      Result := Result + C;
    Inc(I);
  end;
  Result := Result + Quote;
end;

function CodePointOf(const S: string): LongWord;
var
  B: Byte;
  N, I: Integer;
begin
  if S = '' then
    Exit(0);
  B := Ord(S[1]);
  if B < $80 then
    Exit(B);
  if B and $E0 = $C0 then
  begin
    Result := B and $1F;
    N := 1;
  end
  else if B and $F0 = $E0 then
  begin
    Result := B and $0F;
    N := 2;
  end
  else if B and $F8 = $F0 then
  begin
    Result := B and $07;
    N := 3;
  end
  else
    Exit($FFFD);
  for I := 2 to N + 1 do
  begin
    if (I > Length(S)) or (Ord(S[I]) and $C0 <> $80) then
      Exit($FFFD);
    Result := (Result shl 6) or (Ord(S[I]) and $3F);
  end;
end;

function DecodeUtf8(const S: string; I: SizeInt; out Len: SizeInt): LongWord;
var
  B: Byte;
  Want, K: SizeInt;
begin
  B := Ord(S[I]);
  Len := 1;
  if B < $80 then
    Exit(B);
  if B and $E0 = $C0 then
  begin
    Want := 2;
    Result := B and $1F;
  end
  else if B and $F0 = $E0 then
  begin
    Want := 3;
    Result := B and $0F;
  end
  else if B and $F8 = $F0 then
  begin
    Want := 4;
    Result := B and $07;
  end
  else
    Exit($FFFD);
  for K := 1 to Want - 1 do
    if (I + K <= Length(S)) and (Ord(S[I + K]) and $C0 = $80) then
    begin
      Result := (Result shl 6) or (Ord(S[I + K]) and $3F);
      Len := K + 1;
    end
    else
      Exit($FFFD);
end;

function IsWordCodePoint(C: LongWord): Boolean;
var
  Lo, Hi, Mid: Integer;
begin
  if C < $80 then
    Exit(Chr(C) in ['0'..'9', 'A'..'Z', 'a'..'z', '_']);
  Lo := 0;
  Hi := High(WordRanges) div 2;
  while Lo <= Hi do
  begin
    Mid := (Lo + Hi) div 2;
    if C < WordRanges[2 * Mid] then
      Hi := Mid - 1
    else if C > WordRanges[2 * Mid + 1] then
      Lo := Mid + 1
    else
      Exit(True);
  end;
  Result := False;
end;

function IsWordAt(const S: string; I: SizeInt; out Len: SizeInt): Boolean;
begin
  Len := 0;
  if (I < 1) or (I > Length(S)) then
    Exit(False);
  Result := IsWordCodePoint(DecodeUtf8(S, I, Len));
end;

function IsWordBefore(const S: string; I: SizeInt): Boolean;
var
  J, Len: SizeInt;
begin
  if (I <= 1) or (I > Length(S) + 1) then
    Exit(False);
  J := I - 1;
  while (J > 1) and (Ord(S[J]) and $C0 = $80) do
    Dec(J);
  Result := IsWordAt(S, J, Len);
end;

function Utf16Length(const S: string): SizeInt;
var
  I: SizeInt;
  B: Byte;
begin
  Result := 0;
  for I := 1 to Length(S) do
  begin
    B := Ord(S[I]);
    if B and $C0 <> $80 then
      Inc(Result);
    if B >= $F0 then
      Inc(Result);
  end;
end;

function CharOffset(const S: string; N: SizeInt): SizeInt;
var
  I: SizeInt;
begin
  I := 1;
  while (I <= Length(S)) and (N > 0) do
  begin
    Inc(I);
    while (I <= Length(S)) and (Ord(S[I]) and $C0 = $80) do
      Inc(I);
    Dec(N);
  end;
  Result := I - 1;
end;

function CharCopy(const S: string; N: SizeInt): string;
begin
  Result := Copy(S, 1, CharOffset(S, N));
end;

end.
