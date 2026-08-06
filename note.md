# Shake_PPP 作業ノート

このファイルは `D:\DelphiProg\test\SYNC_Motion\note.md` から、このプロジェクトでも使える方針だけを抜き出し、Shake_PPP向けに置き換えたもの。

## プロジェクト構成

- `Shake_PPP.dpr` はDLLのexport境界と必要ユニットの列挙だけを担当する。
- `Source\Shake_PPP_FilterPlugin.pas` はフィルター登録と映像処理の入口を担当する。
- 複数ユニットで共用する処理やSDK定義は `Source\Lib` に置く。
- 参照元から不要なユニットを一括で持ち込まず、実際に使う依存だけを置く。
- 現在の映像コールバックは何も加工せず、成功を返す空実装とする。

## 共通ビルドルール

- Delphi 37.0を使用し、対象プラットフォームはWin64だけとする。
- DebugとReleaseのビルド設定を保つ。
- コンパイル警告とエラーを確認し、原則として警告0、エラー0で完了とする。
- ビルド前に `C:\ProgramData\aviutl2\Plugin\Shake_PPP` がなければ作成し、DLLを同フォルダーへ出力する。
- DebugはDLLを `Shake_PPP.auf2` へコピーし、調査用のDLLとRSMも残す。
- ReleaseはDLLを `Shake_PPP.auf2` へコピーした後、同じ出力先のDLLとRSMを削除する。

Debug Win64:

```powershell
cmd /c "call ""C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat"" && msbuild ""D:\DelphiProg\test\Shake_PPP\Shake_PPP.dproj"" /t:Build /p:Config=Debug /p:Platform=Win64"
```

Release Win64:

```powershell
cmd /c "call ""C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat"" && msbuild ""D:\DelphiProg\test\Shake_PPP\Shake_PPP.dproj"" /t:Build /p:Config=Release /p:Platform=Win64"
```

配備先:

```text
C:\ProgramData\aviutl2\Plugin\Shake_PPP\Shake_PPP.auf2
```

## 実装・保守ルール

- フィルターコールバック境界からDelphi例外を外へ漏らさない。
- 毎フレームの処理ではファイル再読込、不要なメモリ確保、GUI値の書き戻しを行わない。
- コメントは処理の言い換えではなく、目的、責務、注意点、状態や値の意味を補うために書く。
- DelphiのSDKレコードはC/C++側のABIと一致させ、フィールド追加時は順序、型、アラインメントを公式SDKと照合する。
- 責務が増えたら専用ユニットへ分け、グローバルな可変状態を避ける。

## Git管理ルール

- `.pas`、`.dpr`、`.dproj`、`.res`、文書、配布・検証に必要なスクリプトと素材を同期対象とする。
- `Win32`、`Win64`、`.dcu`、`.rsm`、`.dll`、`.auf2`、IDEローカル設定、履歴・復旧データは同期しない。
- `.gitattributes` でPascal、プロジェクト、文書の改行をCRLFへ統一する。
- `.res` などのバイナリーファイルはbinaryとして扱う。

## 作業ログ

- 2026-08-06: SYNC_Motionを参考に、Win64 Debug/Release、ビルド後コピー、空フィルターを備えた最小プロジェクトを作成した。
