# サンプルアプリのアイコン

サンプルのアクセントカラーに合わせた青緑色の背景に、吹き出しと波形を組み合わせています。
画像生成ツールで作成しました。iOS版は不透明な正方形、macOS版は角丸タイル・余白・透明な外周を持つ画像です。
`sips`でデザインを変えず、Asset Catalogに必要な各サイズへ縮小しています。

- iOSの原画像：`Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`
- macOSの原画像：`Assets.xcassets/AppIconMac.appiconset/AppIconMac-1024.png`
- 両方のターゲットのResourcesに`Assets.xcassets`を含めています。
- 任意のプロジェクト再生成スクリプトでも、アイコンとアクセントカラーの設定を保持します。

## 生成時のプロンプト（再現用の英語原文）

```text
Use case: logo-brand
Asset type: production app icon for the SBV2 Core ML speech synthesis sample on iPhone and Mac, square 1024 x 1024.
Primary request: a smart, minimal, polished icon that communicates speech becoming an audio waveform. A single bold ivory speech bubble containing five rounded vertical waveform bars. The mark should be distinctive, calm, geometric, optically balanced, and instantly legible at small sizes.
Scene/backdrop: opaque full-bleed deep teal background, with a very subtle teal gradient that matches a restrained native Apple app interface.
Style/medium: crisp premium digital icon, simple sculpted geometry, subtle depth only, no photorealism, no noisy textures.
Composition/framing: centered glyph occupying approximately 60 percent of the square, generous consistent negative space. Edge-to-edge square canvas with no pre-rounded outside corners and no surrounding presentation mockup.
Text: none.
Constraints: exactly one icon, no lettering, no watermark, no branding from other companies, no microphone, no robot or character, no extra symbols. Opaque background, no alpha.
```

## macOS版への編集プロンプト（再現用の英語原文）

```text
Use case: precise-object-edit
Asset type: macOS app icon for the same SBV2 Core ML speech synthesis sample.
Edit target: the attached generated teal speech-bubble and waveform app icon.
Primary request: preserve the existing icon design exactly, but present the square teal icon as a macOS rounded-square tile with genuinely transparent outside corners and a modest transparent margin on all sides. Keep the teal tile about 82 percent of the total square canvas width. Give the tile smooth superellipse corners and a very subtle small soft shadow, appropriate for the macOS Dock.
Constraints: keep the ivory speech-bubble/waveform mark, its geometry, the existing teal gradient and their relative placement within the tile unchanged. Change only the outer silhouette/padding. No text, no new symbols, no mockup, no white or checkerboard background. Output a square 1024 x 1024 PNG with real alpha transparency.
```
