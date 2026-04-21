(() => {
  const I18N = {
    en: {
      "nav.concept": "Concept",
      "nav.featured": "Highlights",
      "nav.features": "All Features",
      "nav.download": "Download",

      "hero.tagline": "A Modern PC-8801 Emulator for macOS",
      "hero.sub":
        "Built almost entirely with AI. For Apple Silicon, with spatial audio, AI upscaling, and real-time translation.",
      "hero.shotAlt": "Bubilator88 — Hero Shot",
      "hero.credits":
        "The Man I Love © 1987 Thinking Rabbit · The Black Onyx © 1984 BPS · Valis: The Fantasm Soldier © 1986 Nihon Telenet · Xanadu: Dragon Slayer II © 1985 Nihon Falcom · Thexder © 1985 Game Arts · Snatcher © 1988 Konami · Wizardry: Proving Grounds of the Mad Overlord © 1981 Sir-Tech Software / © 1985 ASCII · The Scheme © 1988 Bothtec · Hydlide 3: The Space Memories © 1987 T&amp;E SOFT",
      "cta.download": "Download Latest",
      "cta.github": "View on GitHub",

      "concept.title": "Concept",
      "concept.eyebrow1": "THE EXPERIMENT",
      "concept.h1": "Can AI build an emulator?",
      "concept.p1":
        "Retro PC emulation demands deeply specialized knowledge — undocumented hardware behavior, T-state-accurate timing, and multiple LSIs cooperating in real time. Bubilator88 is the experiment: an emulator where nearly every line of code is written by AI (Claude / Codex).",
      "concept.eyebrow2": "THE MOTIVATION",
      "concept.h2": "A PC-8801, made for the Mac.",
      "concept.p2":
        "Retro PC emulation has long been a Windows-centric world. Mac users were left with virtualization layers or non-native ports. Bubilator88 is built from the ground up for macOS — SwiftUI, Metal, AVAudioEngine, Apple Neural Engine, all the way down.",

      "featured.title": "Featured Highlights",
      "featured.lead": "See, hear, and feel what makes Bubilator88 different.",

      "ba.before": "Original",
      "ba.afterAI": "AI Upscaled",
      "ba.afterFilter": "CRT",
      "ba.afterFilterCrt": "CRT",
      "ba.afterFilterEnhanced": "Enhanced",

      "media.spatial": "Immersive Position Pad",
      "media.translation": "Translation Overlay",
      "media.controller": "Controller + Haptics",
      "media.clip": "Copy & Paste",
      "media.debugger": "Debug Window",

      "audio.mono": "Mono",
      "audio.pseudo": "Pseudo Stereo",
      "audio.hint": "Best experienced with headphones.",

      "credit.upscaler": "Ys II © 1988 Falcom",
      "credit.filter": "Murder Club © 1986 Riverhill Soft",
      "credit.translation": "Murder Club © 1986 Riverhill Soft",
      "credit.controller": "Silpheed © 1986 GAME ARTS",
      "credit.stereo": "Sorcerian © 1987 Falcom",

      "f.upscaler.title": "AI Upscaler",
      "f.upscaler.body":
        "Real-time super-resolution on Apple Neural Engine. Sharpen 640×400 pixel art while preserving edges and detail — three model sizes from ultra-fast to reference quality.",
      "f.filter.title": "Signature Screen Filters",
      "f.filter.body":
        "Two signature filters: CRT for authentic scanlines and phosphor afterglow, and Enhanced — an extended take on xBRZ, tuned for PC-88 pixel art. Both run as native Metal shaders for 60 fps playback, even at retina resolution.",
      "f.spatial.title": "Immersive Spatial Audio",
      "f.spatial.body":
        "Place each sound channel — FM, SSG, ADPCM, Rhythm — anywhere in 3D space using an intuitive position pad. Head-tracked through AirPods for true immersive audio.<small class=\"note\">* Compatible earphones or headphones required.</small>",
      "f.translate.title": "Real-time Translation",
      "f.translate.body":
        "For non-Japanese players who want to enjoy Japanese games — especially adventure titles. Apple Vision OCR reads the on-screen Japanese in real time, and the Translation framework overlays your language right on top.",
      "f.controller.title": "Controller + Haptics",
      "f.controller.body":
        "Full game controller support with rumble synced to SSG sound effects. Every explosion, every footstep — you can feel it in your hands, just like the arcade.<small class=\"note\">* Requires a macOS-compatible game controller.</small>",
      "f.stereo.title": "Pseudo Stereo",
      "f.stereo.body":
        "Add subtle per-channel delay differences to a mono source and retro music opens up into a wider stage. Compare the before and after — the effect is unmistakable on headphones.",
      "f.clip.title": "Copy & Paste",
      "f.clip.body":
        "Copy on-screen text straight into the macOS clipboard, or paste BASIC listings back into the emulator as keystrokes — no more hand-typing program magazines.",
      "f.debug.title": "Full-Featured Debugger",
      "f.debug.body":
        "Disassembler, dual-CPU registers, six breakpoint types, instruction and PIO ring-buffer tracing with JSONL export, GVRAM and Text VRAM inspectors, and a live spectrum analyzer with per-channel mute.",

      "features.title": "Other Features",
      "features.lead": "The essentials that make the emulator tick.",
      "features.cpu.title": "Z80 T-State Accurate",
      "features.cpu.body":
        "Instruction-granular timing. Software-visible hardware behavior, reproduced faithfully.",
      "features.ym.title": "YM2608 (OPNA)",
      "features.ym.body":
        "FM 6ch + SSG 3ch + Rhythm + ADPCM. Low-latency output via AVAudioEngine.",
      "features.save.title": "Save States",
      "features.save.body":
        "10 slots plus Quick Save (Cmd+S / Cmd+L). Thumbnails and metadata per slot.",
      "features.disk.title": "Disk & Tape",
      "features.disk.body":
        "D88 / D77 / 2D / 2HD floppies, T88 / CMT tapes. Open <strong>ZIP / LZH / CAB / RAR</strong> archives directly — just pick the image you want inside.",
      "features.native.title": "Apple Silicon Native",
      "features.native.body":
        "Built with SwiftUI, Metal, AVAudioEngine, and CoreML. Optimized for M-series Macs.",
      "features.fdd.title": "FDD Sound FX",
      "features.fdd.body":
        "Authentic floppy drive seek and access sounds. Togglable in settings.",

      "req.title": "Requirements",
      "req.os": "macOS 26.0 (Tahoe) or later",
      "req.cpu":
        "Apple Silicon (M1 or later). M4 Pro+ recommended for AI Upscaling.",
      "req.rom":
        "PC-8801 ROM files are <strong>not</strong> included. Place them in <code>~/Library/Application Support/Bubilator88/</code>.",

      "dl.title": "Download & Get Started",
      "dl.s1.title": "Download",
      "dl.s1.body": "Grab the latest <code>.app</code> from GitHub Releases.",
      "dl.s2.title": "Bypass Gatekeeper",
      "dl.s2.body":
        "The app is not notarized. Run <code>xattr -cr /Applications/Bubilator88.app</code> or allow it from System Settings &gt; Privacy &amp; Security.",
      "dl.s3.title": "Add ROM files",
      "dl.s3.body":
        "Drop <code>N88.ROM</code>, <code>DISK.ROM</code>, and friends into <code>~/Library/Application Support/Bubilator88/</code>. See the README for the full list.",

      "acks.title": "Acknowledgements",
      "acks.lead": "Bubilator88 stands on the shoulders of incredible prior work. Deep thanks to everyone below.",
      "acks.fmgen.role": "FM Synthesis",
      "acks.fmgen.body": "Ported to Swift as the core of the YM2608 sound engine.",
      "acks.quasi88.role": "Behavior Reference",
      "acks.quasi88.body": "Consulted constantly as the authoritative behavioral reference.",
      "acks.csc.role": "Reference Emulator",
      "acks.csc.body": "Another indispensable reference implementation (BubiC-8801MA).",
      "acks.x88000.role": "Reference Emulator",
      "acks.x88000.body": "A third indispensable reference, especially for Z80 undocumented instructions and countless implementation details.",
      "acks.youkan.role": "Hardware Docs",
      "acks.youkan.body": "The go-to dictionary for PC-8801 hardware specifications.",
      "acks.vram.role": "VRAM Spec",
      "acks.vram.body": "The definitive guide to VRAM access behavior.",
      "acks.xbrz.role": "Scaling Algorithm",
      "acks.xbrz.body": "The pixel-art scaling algorithm that became the base of the Enhanced filter.",
      "acks.resrgan.role": "AI Model",
      "acks.resrgan.body": "Base super-resolution model, converted to CoreML.",
      "acks.ai.role": "AI Pair Programmers",
      "acks.ai.body": "The partners who actually wrote nearly every line of this code.",

      "footer.credit": "Built almost entirely with Claude Code & Codex.",
      "footer.issues": "Issues",
      "footer.license": "License (GPL-2.0)",
    },
    ja: {
      "nav.concept": "コンセプト",
      "nav.featured": "注目機能",
      "nav.features": "機能一覧",
      "nav.download": "ダウンロード",

      "hero.tagline": "Mac のための、新しい PC-8801。",
      "hero.sub":
        "コードはほぼ全部 AI が書いた。空間オーディオも、AI アップスケールも、リアルタイム翻訳も — Apple Silicon でぜんぶ動きます。",
      "hero.shotAlt": "Bubilator88 メインビジュアル",
      "hero.credits":
        "ザ・マン・アイ・ラブ © 1987 シンキングラビット ／ ザ・ブラックオニキス © 1984 ビーピーエス ／ 夢幻戦士ヴァリス © 1986 日本テレネット ／ ザナドゥ © 1985 日本ファルコム ／ テグザー © 1985 ゲームアーツ ／ スナッチャー © 1988 コナミ ／ ウィザードリィ #1 -狂王の試練場- © 1981 Sir-Tech Software ／ © 1985 アスキー ／ ザ・スキーム © 1988 ボーステック ／ ハイドライド3 -異次元の思い出- © 1987 ティーアンドイーソフト",
      "cta.download": "ダウンロード",
      "cta.github": "GitHub を見る",

      "concept.title": "コンセプト",
      "concept.eyebrow1": "THE EXPERIMENT",
      "concept.h1": "AI って、エミュレータも書けるの？",
      "concept.p1":
        "ドキュメントに載ってないハードの癖、T ステート単位でシビアなタイミング、いくつもの LSI がお互いに合わせて動く挙動 — レトロ PC のエミュレーションって、かなりマニアックで地道な世界です。そのコードをほぼ全部 AI (Claude / Codex) に書かせてみたら、どこまでいけるのか。Bubilator88 はその実験から生まれました。",
      "concept.eyebrow2": "THE MOTIVATION",
      "concept.h2": "そして、Mac で PC-88 がやりたかった。",
      "concept.p2":
        "レトロ PC のエミュレータって、Windows　用のものが多い。それかマルチプラットフォーム　用。「もっと Mac らしく動くやつがあったらいいのに」— その気持ちだけで作り始めたのが Bubilator88 です。SwiftUI、Metal、AVAudioEngine、Neural Engine — 全部 Mac ネイティブでフル活用しています。",

      "featured.title": "注目の機能",
      "featured.lead":
        "見て、聴いて、触って。Bubilator88 の違いを体感してください。",

      "ba.before": "オリジナル",
      "ba.afterAI": "AI アップスケール",
      "ba.afterFilter": "CRT",
      "ba.afterFilterCrt": "CRT",
      "ba.afterFilterEnhanced": "Enhanced",

      "media.spatial": "イマーシブ ポジションパッド",
      "media.translation": "翻訳オーバーレイ",
      "media.controller": "コントローラー & ハプティクス",
      "media.clip": "コピー & ペースト",
      "media.debugger": "デバッグウィンドウ",

      "audio.mono": "モノラル",
      "audio.pseudo": "擬似ステレオ",
      "audio.hint": "ヘッドフォンで聴くのがオススメです。",

      "credit.upscaler": "イース II © 1988 Falcom",
      "credit.filter": "殺人倶楽部(マーダークラブ) © 1986 Riverhill Soft",
      "credit.translation": "殺人倶楽部(マーダークラブ) © 1986 Riverhill Soft",
      "credit.controller": "シルフィード © 1986 GAME ARTS",
      "credit.stereo": "ソーサリアン © 1987 Falcom",

      "f.upscaler.title": "AI アップスケーラー",
      "f.upscaler.body":
        "Apple Neural Engine で超解像モデルをリアルタイム実行。640×400 のドット絵を、エッジもディテールもキープしたままグッと高解像度に。速度重視から画質重視まで 3 モデルから選べます。",
      "f.filter.title": "こだわりの画面フィルター",
      "f.filter.body":
        "ブラウン管の走査線と蛍光体残光を再現する CRT と、xBRZ をベースに拡張したドット絵向け Enhanced — 代表的な 2 つのフィルターを搭載。全部 Metal シェーダ実装なので、Retina でも 60fps でヌルヌル動きます。",
      "f.spatial.title": "空間オーディオ",
      "f.spatial.body":
        "FM・SSG・ADPCM・リズムの各チャンネルを、ポジションパッドで 3D 空間に自由配置。AirPods ならヘッドトラッキングで、首を動かすと音の位置が変わります。<small class=\"note\">※ 対応するイヤホン／ヘッドフォンが必要です。</small>",
      "f.translate.title": "リアルタイム翻訳",
      "f.translate.body":
        "日本語が読めない海外のプレイヤー向けの機能です。アドベンチャーゲームみたいな「文章を読むゲーム」でも、Apple の Vision OCR が画面の日本語を読み取って、Translation フレームワークが好きな言語に翻訳してその場でオーバーレイ表示します。",
      "f.controller.title": "コントローラー & ハプティクス",
      "f.controller.body":
        "ゲームコントローラーに対応。さらに SSG の効果音に合わせてコントローラーが振動するので、爆発や足音がちゃんと手に伝わります。アーケードっぽくなる。<small class=\"note\">※ macOS が対応するゲームコントローラーが必要です。</small>",
      "f.stereo.title": "擬似ステレオ",
      "f.stereo.body":
        "モノラルの各チャンネルに左右で少しだけディレイをかけて、音に広がりをプラス。Before / After を聴き比べると、ヘッドフォンだと違いは一発で分かるはず。",
      "f.clip.title": "コピー & ペースト",
      "f.clip.body":
        "エミュ画面のテキストを macOS のクリップボードへコピー。逆に、クリップボードの BASIC リストをそのまま流し込むこともできます。雑誌のプログラムを手打ちしなくていい時代が来ました。",
      "f.debug.title": "ガチのデバッガ",
      "f.debug.body":
        "逆アセンブラ、メイン/サブ両 CPU のレジスタ、6 種類のブレークポイント、命令 / PIO リングバッファトレース (JSONL で書き出し可)、GVRAM / Text VRAM ビューア、チャンネル別ミュート付きスペアナ。作る人にも優しい。",

      "features.title": "その他の機能",
      "features.lead": "エミュレータの土台になっている基本機能たち。",
      "features.cpu.title": "Z80 T ステート精度",
      "features.cpu.body":
        "命令単位でタイミング制御。ソフトから見えるハードの挙動を、できるかぎり忠実に。",
      "features.ym.title": "YM2608 (OPNA)",
      "features.ym.body":
        "FM 6ch + SSG 3ch + リズム + ADPCM。AVAudioEngine で低遅延出力。",
      "features.save.title": "セーブステート",
      "features.save.body":
        "スロット 10 個 + クイックセーブ (Cmd+S / Cmd+L)。サムネとメタ情報もちゃんと残ります。",
      "features.disk.title": "ディスク & テープ",
      "features.disk.body":
        "D88 / D77 / 2D / 2HD のディスク、T88 / CMT のテープに対応。<strong>ZIP / LZH / CAB / RAR</strong> の圧縮ファイルは、展開せずそのまま開いて中のイメージを選べます。",
      "features.native.title": "Apple Silicon ネイティブ",
      "features.native.body":
        "SwiftUI、Metal、AVAudioEngine、CoreML でガッツリ構築。M シリーズに最適化済み。",
      "features.fdd.title": "FDD アクセス音",
      "features.fdd.body":
        "フロッピーのシーク音・アクセス音までちゃんと再現。設定でオフにもできます。",

      "req.title": "動作環境",
      "req.os": "macOS 26.0 (Tahoe) 以降",
      "req.cpu":
        "Apple Silicon (M1 以降)。AI アップスケールは M4 Pro 以上があると安心。",
      "req.rom":
        "PC-8801 の ROM は <strong>同梱していません</strong>。自分で用意して <code>~/Library/Application Support/Bubilator88/</code> に置いてください。",

      "dl.title": "ダウンロード & はじめかた",
      "dl.s1.title": "ダウンロード",
      "dl.s1.body":
        "GitHub Releases から最新の <code>.app</code> を取ってきます。",
      "dl.s2.title": "Gatekeeper を通す",
      "dl.s2.body":
        "公証を取ってないので、<code>xattr -cr /Applications/Bubilator88.app</code> を実行するか、「システム設定 &gt; プライバシーとセキュリティ」から「このまま開く」でどうぞ。",
      "dl.s3.title": "ROM を置く",
      "dl.s3.body":
        "<code>N88.ROM</code> や <code>DISK.ROM</code> などを <code>~/Library/Application Support/Bubilator88/</code> に放り込みます。一覧は README にまとめてあります。",

      "acks.title": "謝辞",
      "acks.lead": "Bubilator88 は、先人たちの素晴らしい成果の上に成り立っています。みなさんに心から感謝します。",
      "acks.fmgen.role": "FM 合成エンジン",
      "acks.fmgen.body": "YM2608 サウンドエンジンの中核として、Swift に移植させてもらっています。",
      "acks.quasi88.role": "挙動リファレンス",
      "acks.quasi88.body": "困ったときはまずここ。ずっと挙動の答え合わせに使わせてもらってます。",
      "acks.csc.role": "参考実装",
      "acks.csc.body": "もうひとつの強力なリファレンス実装 (BubiC-8801MA)。本当にお世話になってます。",
      "acks.x88000.role": "参考実装",
      "acks.x88000.body": "Z80 未文書化命令や細かな実装のディテールで、何度も参考にさせてもらっています。",
      "acks.youkan.role": "ハードウェア資料",
      "acks.youkan.body": "PC-8801 ハード仕様の辞書的存在。何度も開きました。",
      "acks.vram.role": "VRAM 仕様",
      "acks.vram.body": "VRAM アクセス仕様の決定版ドキュメント。",
      "acks.xbrz.role": "スケーリングアルゴリズム",
      "acks.xbrz.body": "Enhanced フィルターのベースになったドット絵向けスケーラー。素晴らしいアルゴリズムです。",
      "acks.resrgan.role": "AI モデル",
      "acks.resrgan.body": "超解像モデルのベース。CoreML に変換して使わせてもらっています。",
      "acks.ai.role": "AI 相棒",
      "acks.ai.body": "このプロジェクトのコードをほぼ全部書いてくれた、頼れる相棒たち。",

      "footer.credit": "コードはほぼ全部 Claude Code と Codex が書きました。",
      "footer.issues": "Issues",
      "footer.license": "ライセンス (GPL-2.0)",
    },
  };

  const STORAGE_KEY = "bubilator88.lang";

  function detectInitialLang() {
    const stored = localStorage.getItem(STORAGE_KEY);
    if (stored === "ja" || stored === "en") return stored;
    const browser = (navigator.language || "en").toLowerCase();
    return browser.startsWith("ja") ? "ja" : "en";
  }

  function applyLang(lang) {
    const dict = I18N[lang] || I18N.en;
    document.documentElement.lang = lang;
    document.querySelectorAll("[data-i18n]").forEach((el) => {
      const key = el.getAttribute("data-i18n");
      if (dict[key] != null) el.innerHTML = dict[key];
    });
    document.querySelectorAll("[data-lang]").forEach((el) => {
      el.classList.toggle("active", el.getAttribute("data-lang") === lang);
    });
    localStorage.setItem(STORAGE_KEY, lang);
  }

  function initLangToggle() {
    const btn = document.getElementById("langToggle");
    if (!btn) return;
    btn.addEventListener("click", () => {
      const current = localStorage.getItem(STORAGE_KEY) || detectInitialLang();
      applyLang(current === "ja" ? "en" : "ja");
    });
  }

  function initBASliders() {
    document.querySelectorAll(".ba-slider").forEach((slider) => {
      const input = slider.querySelector(".ba-slider-input");
      if (!input) return;
      const apply = () => slider.style.setProperty("--split", input.value + "%");
      input.addEventListener("input", apply);
      apply();
    });
  }

  function initBAFilterToggle() {
    document.querySelectorAll("[data-ba-segmented]").forEach((group) => {
      const slider = group.nextElementSibling;
      if (!slider || !slider.matches("[data-ba-filter-slider]")) return;
      const afterImg = slider.querySelector(".ba-slider-after");
      const afterLabel = slider.querySelector(".ba-label-after");
      const placeholderText = slider.querySelector("[data-filter-placeholder]");
      const placeholder = slider.querySelector(".ba-placeholder-after");
      const labelKey = {
        crt: "ba.afterFilterCrt",
        enhanced: "ba.afterFilterEnhanced",
      };
      const placeholderText_ = { crt: "CRT", enhanced: "Enhanced" };
      const buttons = group.querySelectorAll(".ba-seg");
      buttons.forEach((btn) => {
        btn.addEventListener("click", () => {
          const filter = btn.dataset.filter;
          const src = afterImg?.dataset["src" + filter[0].toUpperCase() + filter.slice(1)];
          if (src && afterImg) {
            afterImg.style.display = "";
            if (placeholder) placeholder.style.display = "none";
            afterImg.src = src;
          }
          if (placeholderText) placeholderText.textContent = placeholderText_[filter] ?? filter;
          if (afterLabel) {
            afterLabel.setAttribute("data-i18n", labelKey[filter]);
          }
          buttons.forEach((b) => {
            const on = b === btn;
            b.classList.toggle("active", on);
            b.setAttribute("aria-selected", on ? "true" : "false");
          });
          // Re-apply the active language so the label text updates immediately.
          applyLang(localStorage.getItem(STORAGE_KEY) || detectInitialLang());
        });
      });
    });
  }

  function initAudioAB() {
    const fmtTime = (s) => {
      if (!isFinite(s) || s < 0) return "0:00";
      const sec = Math.floor(s);
      return Math.floor(sec / 60) + ":" + String(sec % 60).padStart(2, "0");
    };

    document.querySelectorAll("[data-audio-ab]").forEach((group) => {
      const audios = group.querySelectorAll("audio");
      if (audios.length !== 2) return;
      const [master, slave] = audios;

      // Mirror slave's play/pause/seek/rate to master
      master.addEventListener("play", () => { slave.play().catch(() => {}); });
      master.addEventListener("pause", () => { slave.pause(); });
      master.addEventListener("seeking", () => { slave.currentTime = master.currentTime; });
      master.addEventListener("ratechange", () => { slave.playbackRate = master.playbackRate; });
      master.addEventListener("ended", () => { slave.pause(); });

      slave.muted = true;
      master.muted = false;

      // Variant toggle (Mono / Pseudo Stereo): mute inactive audio
      const buttons = group.querySelectorAll(".ba-seg");
      buttons.forEach((btn) => {
        btn.addEventListener("click", () => {
          const variant = btn.dataset.audioVariant;
          audios.forEach((a) => { a.muted = a.dataset.variant !== variant; });
          buttons.forEach((b) => {
            const on = b === btn;
            b.classList.toggle("active", on);
            b.setAttribute("aria-selected", on ? "true" : "false");
          });
        });
      });

      // Custom controls: play/pause + scrub only
      const controls = group.querySelector("[data-audio-controls]");
      if (!controls) return;
      const playBtn = controls.querySelector(".audio-play");
      const scrub = controls.querySelector(".audio-scrub");
      const curEl = controls.querySelector(".audio-time-current");
      const totEl = controls.querySelector(".audio-time-total");

      const updateProgress = () => {
        const dur = master.duration;
        if (isFinite(dur) && dur > 0) {
          const ratio = master.currentTime / dur;
          scrub.value = Math.round(ratio * 1000);
          scrub.style.setProperty("--progress", (ratio * 100).toFixed(2) + "%");
        }
        if (curEl) curEl.textContent = fmtTime(master.currentTime);
      };

      const updateDuration = () => {
        if (totEl) totEl.textContent = fmtTime(master.duration);
      };

      playBtn?.addEventListener("click", () => {
        if (master.paused) master.play().catch(() => {});
        else master.pause();
      });
      master.addEventListener("play", () => controls.classList.add("is-playing"));
      master.addEventListener("pause", () => controls.classList.remove("is-playing"));
      master.addEventListener("timeupdate", updateProgress);
      master.addEventListener("loadedmetadata", updateDuration);
      master.addEventListener("durationchange", updateDuration);

      scrub?.addEventListener("input", () => {
        const dur = master.duration;
        if (isFinite(dur) && dur > 0) {
          master.currentTime = (Number(scrub.value) / 1000) * dur;
          scrub.style.setProperty("--progress", ((Number(scrub.value) / 1000) * 100).toFixed(2) + "%");
        }
      });

      if (master.readyState >= 1) updateDuration();
      updateProgress();
    });
  }

  function initReveal() {
    const els = document.querySelectorAll(".reveal");
    if (!("IntersectionObserver" in window)) {
      els.forEach((el) => el.classList.add("visible"));
      return;
    }
    const io = new IntersectionObserver(
      (entries) => {
        entries.forEach((e) => {
          if (e.isIntersecting) {
            e.target.classList.add("visible");
            io.unobserve(e.target);
          }
        });
      },
      { threshold: 0.12 },
    );
    els.forEach((el) => io.observe(el));
  }

  document.addEventListener("DOMContentLoaded", () => {
    applyLang(detectInitialLang());
    initLangToggle();
    initBASliders();
    initBAFilterToggle();
    initAudioAB();
    initReveal();
  });
})();
