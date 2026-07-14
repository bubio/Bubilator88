using System.Collections.Generic;
using System.Text;
using Windows.Foundation;

namespace Bubilator88.Windows.Ocr;

/// <summary>
/// One OCR-detected text line. <see cref="NormalizedRect"/> is 0..1, top-left
/// origin, relative to the image that was OCR'd (unlike Vision on macOS,
/// Windows.Media.Ocr's OcrWord.BoundingRect is already top-left-origin, so no
/// Y-flip is needed when producing this from an OcrLine).
/// </summary>
internal readonly record struct OcrDetection(Rect NormalizedRect, string Text);

/// <summary>
/// Dependency-free text helpers for the OCR pipeline: Japanese-script
/// detection and katakana normalization. Mirrors macOS TranslationManager's
/// isJapanese(_:)/katakanaToHiragana(_:) so a future translation step can
/// reuse KatakanaToHiragana without re-deriving it.
///
/// Every Japanese/kana literal below was verified against its expected
/// U+XXXX code point (see the implementation plan's verification notes)
/// rather than assumed from how it renders in an editor/font.
/// </summary>
internal static class OcrTypes
{
    public static bool ContainsJapanese(string text)
    {
        foreach (char c in text)
        {
            if (IsJapanese(c)) return true;
        }
        return false;
    }

    private static bool IsJapanese(char c) => c switch
    {
        >= '぀' and <= 'ゟ' => true, // Hiragana
        >= '゠' and <= 'ヿ' => true, // Katakana
        >= '一' and <= '鿿' => true, // CJK Unified Ideographs
        >= '｡' and <= 'ﾟ' => true, // Half-width Katakana
        >= '　' and <= '〿' => true, // CJK Symbols and Punctuation
        _ => false,
    };

    // Half-width katakana (JIS X0201, U+FF61-U+FF9F) -> full-width equivalent.
    // Index 0 = U+FF61. U+FF9E/FF9F map to the combining dakuten/handakuten
    // marks (U+3099/U+309A), resolved against the preceding base character by
    // NormalizeHalfwidthKatakana via VoicedPairs below.
    private static readonly char[] HalfToFullwidth =
    {
        '。', '「', '」', '、', '・', // FF61-65: 。「」、・
        'ヲ', 'ァ', 'ィ', 'ゥ', 'ェ', 'ォ', // FF66-6B: ヲァィゥェォ
        'ャ', 'ュ', 'ョ', 'ッ', 'ー', // FF6C-70: ャュョッー
        'ア', 'イ', 'ウ', 'エ', 'オ', // FF71-75: アイウエオ
        'カ', 'キ', 'ク', 'ケ', 'コ', // FF76-7A: カキクケコ
        'サ', 'シ', 'ス', 'セ', 'ソ', // FF7B-7F: サシスセソ
        'タ', 'チ', 'ツ', 'テ', 'ト', // FF80-84: タチツテト
        'ナ', 'ニ', 'ヌ', 'ネ', 'ノ', // FF85-89: ナニヌネノ
        'ハ', 'ヒ', 'フ', 'ヘ', 'ホ', // FF8A-8E: ハヒフヘホ
        'マ', 'ミ', 'ム', 'メ', 'モ', // FF8F-93: マミムメモ
        'ヤ', 'ユ', 'ヨ', // FF94-96: ヤユヨ
        'ラ', 'リ', 'ル', 'レ', 'ロ', // FF97-9B: ラリルレロ
        'ワ', 'ン', // FF9C-9D: ワン
        '゙', '゚', // FF9E-9F: combining dakuten/handakuten
    };

    // (unvoiced full-width base, combining mark) -> voiced full-width kana.
    private static readonly Dictionary<(char BaseChar, char Mark), char> VoicedPairs = new()
    {
        [('カ', '゙')] = 'ガ', // カ -> ガ
        [('キ', '゙')] = 'ギ', // キ -> ギ
        [('ク', '゙')] = 'グ', // ク -> グ
        [('ケ', '゙')] = 'ゲ', // ケ -> ゲ
        [('コ', '゙')] = 'ゴ', // コ -> ゴ
        [('サ', '゙')] = 'ザ', // サ -> ザ
        [('シ', '゙')] = 'ジ', // シ -> ジ
        [('ス', '゙')] = 'ズ', // ス -> ズ
        [('セ', '゙')] = 'ゼ', // セ -> ゼ
        [('ソ', '゙')] = 'ゾ', // ソ -> ゾ
        [('タ', '゙')] = 'ダ', // タ -> ダ
        [('チ', '゙')] = 'ヂ', // チ -> ヂ
        [('ツ', '゙')] = 'ヅ', // ツ -> ヅ
        [('テ', '゙')] = 'デ', // テ -> デ
        [('ト', '゙')] = 'ド', // ト -> ド
        [('ハ', '゙')] = 'バ', // ハ -> バ
        [('ヒ', '゙')] = 'ビ', // ヒ -> ビ
        [('フ', '゙')] = 'ブ', // フ -> ブ
        [('ヘ', '゙')] = 'ベ', // ヘ -> ベ
        [('ホ', '゙')] = 'ボ', // ホ -> ボ
        [('ウ', '゙')] = 'ヴ', // ウ -> ヴ
        [('ハ', '゚')] = 'パ', // ハ -> パ
        [('ヒ', '゚')] = 'ピ', // ヒ -> ピ
        [('フ', '゚')] = 'プ', // フ -> プ
        [('ヘ', '゚')] = 'ペ', // ヘ -> ペ
        [('ホ', '゚')] = 'ポ', // ホ -> ポ
    };

    /// <summary>
    /// Convert katakana to hiragana so a future translation step doesn't mistake
    /// katakana-rendered PC-8801 text for a loanword and merely romanize it
    /// instead of translating it. Mirrors macOS
    /// TranslationManager.katakanaToHiragana(_:) (half-width to full-width
    /// normalization, then full-width katakana to hiragana). Not called from
    /// the OCR-only overlay yet — kept ready for the translation follow-up.
    /// </summary>
    public static string KatakanaToHiragana(string text)
    {
        string fullwidth = NormalizeHalfwidthKatakana(text);

        var sb = new StringBuilder(fullwidth.Length);
        foreach (char c in fullwidth)
        {
            // U+30A1 (small A) .. U+30F6 (small KE): full-width katakana block
            // that has a direct hiragana counterpart 0x60 below it.
            if (c is >= 'ァ' and <= 'ヶ')
                sb.Append((char)(c - 0x60));
            else
                sb.Append(c);
        }
        return sb.ToString();
    }

    private static string NormalizeHalfwidthKatakana(string text)
    {
        var sb = new StringBuilder(text.Length);
        char? pendingBase = null;

        foreach (char c in text)
        {
            char mapped = c is >= '｡' and <= 'ﾟ' ? HalfToFullwidth[c - '｡'] : c;

            if (mapped is '゙' or '゚')
            {
                if (pendingBase is char b && VoicedPairs.TryGetValue((b, mapped), out char voiced))
                {
                    sb.Length--; // replace the un-voiced base already appended
                    sb.Append(voiced);
                }
                else
                {
                    sb.Append(mapped);
                }
                pendingBase = null;
                continue;
            }

            sb.Append(mapped);
            pendingBase = mapped;
        }
        return sb.ToString();
    }
}
