# Windows SmartScreen Warning -- Workaround

When you run `Echo-Setup-x64.exe` on Windows you may see a blue
**"Windows protected your PC"** dialog from Microsoft Defender SmartScreen, with
the publisher listed as **"Unknown publisher"**. This is expected for the
current builds and **does not mean the installer is unsafe**.

## Why this happens

Windows SmartScreen flags any executable that is **not signed by a
Microsoft-trusted code-signing certificate**, or that is signed but has not yet
built up a download-reputation history. Echo Messenger is in the second
category: the installer is not yet signed, so every release shows the warning
until we acquire and roll out a code-signing certificate. The installer itself
is built deterministically from this repository by the
[`release.yml`](../.github/workflows/release.yml) GitHub Actions workflow on
every push to `main`; you can audit exactly what goes into it.

## One-time bypass (per installer version)

You only have to do this once for each version of `Echo-Setup-x64.exe` you
download. New versions will trigger the warning again until signing is in
place.

### Option A -- "More info" → "Run anyway" (fastest)

1. Double-click `Echo-Setup-x64.exe` as normal.
2. When the blue **"Windows protected your PC"** dialog appears, click the
   small **"More info"** link near the top of the dialog.
3. A new **"Run anyway"** button appears at the bottom. Click it.
4. The installer launches normally. Continue through Inno Setup.

### Option B -- Unblock the file from Properties

If "Run anyway" does not appear (some Windows policies hide it), unblock the
file first:

1. In File Explorer, right-click the downloaded `Echo-Setup-x64.exe`.
2. Choose **Properties**.
3. On the **General** tab, find the **Security** notice near the bottom that
   reads *"This file came from another computer and might be blocked..."*
4. Tick the **Unblock** checkbox.
5. Click **OK**.
6. Double-click the installer; the warning should no longer appear.

### Verifying you have the real installer

Each release publishes SHA-256 checksums on the
[Releases page](https://github.com/NC1107/echo-messenger/releases/latest). You
can confirm the file matches by running in PowerShell:

```powershell
Get-FileHash .\Echo-Setup-x64.exe -Algorithm SHA256
```

Compare the output against the checksum listed on the release.

## Roadmap

We are evaluating an EV code-signing certificate. Once it is in place and the
signed installer has built up enough installs for SmartScreen reputation, this
warning will go away entirely and no manual bypass will be needed. Standard
(OV) certs would also remove the "Unknown publisher" string immediately but
still require some reputation history before the SmartScreen prompt
disappears.

Filed as [#903](https://github.com/NC1107/echo-messenger/issues/903).
