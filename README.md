# Trace

**Click a Dropbox link, get the file in Finder.**

Someone sends you a Dropbox link in Slack. You click it, a browser tab opens,
you wait for a preview to load, and then you hunt for the same file in Finder
because that's where you actually needed it.

Trace skips all of that. Click the link, Finder opens with the file selected.

For macOS 26 (Tahoe) or later. Free, and it updates itself.

---

## Installing

1. Download the latest version from
   [Releases](https://github.com/Programme-Studio/Trace/releases/latest).
2. Drag **Trace** to your Applications folder.
3. Open it. Trace is notarised by Apple, so macOS won't warn you about it.

Trace lives in the menu bar — the small box icon at the top of your screen.
There's no Dock icon and no window unless you open Settings.

**You'll also need the Dropbox desktop app** installed and syncing. Trace opens
files that are already on your Mac; it doesn't download anything.

## Setting it up

Click the menu bar icon → **Settings**. There are two things to do.

**1. Connect your Dropbox** (Settings → Dropbox)

Click **Connect Dropbox**. Your browser opens Dropbox's approval page, where
the app appears as `Trace_Programme`. Sign in, approve, and copy the code it
gives you. Trace pastes it in for you.

You're signing into _your own_ Dropbox. Trace gets read-only permission to look
up where files live, and nothing else.

**2. Make Trace your default browser** (Settings → General)

This one surprises people, so here's why: macOS gives an app no way to receive a
clicked link unless that app is the default browser. There's no setting for
"only send me Dropbox links".

So Trace takes the slot, keeps the Dropbox links, and passes **everything else
straight through to your real browser, untouched**. You pick which browser that
is in Settings → General. In practice nothing about your browsing changes — links
open where they always did, and Trace stays out of the way.

If you'd rather stop, Settings → General → **Give it back** hands the slot
straight back to your browser.

That's it. Trace now handles Dropbox links.

## What happens when you click a link

| What you clicked                    | What happens                                                                                    |
| ----------------------------------- | ----------------------------------------------------------------------------------------------- |
| A Dropbox link to a file you sync   | Finder opens with the file selected                                                             |
| A link you've opened before         | The same, instantly — no internet needed                                                        |
| A file in a folder you don't sync   | Opens in your browser, and Trace tells you which folder it's in                                 |
| Anything that isn't a Dropbox link  | Goes to your browser, exactly as before                                                         |
| A new Dropbox link while offline    | Opens in your browser. Links you've opened before still go straight to Finder                   |
| Dropbox is slow to answer           | Opens in your browser after the timeout; Trace keeps looking, so the next click goes to Finder  |

**A click is never lost.** If Trace can't place a file locally, the link goes to
your browser anyway. You end up where you would have without Trace — never
nowhere. The menu bar list shows the reason for each recent link if you want it.

## Settings

| Pane | What's in it |
|---|---|
| **Status** | Whether everything's working, and a box to test a link. Start here |
| **General** | Default browser, which browser gets other links, start at login, reveal vs. open the file |
| **Dropbox** | Your account, which folders you sync, disconnecting |
| **Activity** | Recent links |
| **Advanced** | Cached paths, timeout, diagnostics, repairing registration, reset |

## If something isn't working

**Links open in the browser instead of Finder.** Usually the file just isn't
synced to this Mac — Dropbox's selective sync leaves some folders online-only.
Settings → Dropbox lists your folders with a tick next to the synced ones. To
check a specific link, paste it into Settings → Status → **Test a link**; it
tells you exactly where the file is and why it couldn't be opened.

**Clicking links does nothing at all.** macOS is probably routing clicks to an
old copy of the app. Settings → Advanced → **Repair**. This is the most
common cause of "it worked yesterday".

**Work or team links fail, personal ones work.** Settings → Dropbox → **Re-check**.
That re-detects which Dropbox folder your account's files live in.

**It stopped working after a while.** Settings → Dropbox → Disconnect, then
connect again.

Still stuck? Settings → Advanced → Diagnostics → **Copy** gathers everything
relevant, and you can paste it into an
[issue](https://github.com/Programme-Studio/Trace/issues).

## What Trace can see

Worth being specific, since you're granting access to your Dropbox and making an
app your default browser.

- Trace asks Dropbox for **three read-only permissions**: your account's email,
  where files live, and what a share link points at. It cannot read file
  contents, and it cannot change or delete anything.
- Your Dropbox sign-in is stored in **your Mac's Keychain**. It never leaves your
  computer.
- There is **no server**. Trace talks to Dropbox and to your own filesystem.
  Nothing is sent anywhere else, and there's no analytics of any kind.
- Links you open are kept in a **short in-memory list** so the menu can show
  recent ones. It's gone when you quit, and you can turn it off in
  Settings → Activity.
- Trace posts no notifications and asks for no notification permission.
- Being your default browser means macOS hands Trace every link you click.
  Non-Dropbox links are passed to your browser without being logged, inspected
  or modified.

## Uninstalling

1. Settings → General → **Give it back**, so your browser takes the slot.
2. Settings → Dropbox → **Disconnect**, then revoke Trace under
   [Connected apps](https://www.dropbox.com/account/connected_apps).
3. Drag Trace from Applications to the Trash.
