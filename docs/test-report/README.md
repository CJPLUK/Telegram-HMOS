# Telegram for HarmonyOS Test Report

[中文](README.zh-CN.md) | English

| Item | Details |
|---|---|
| Project under test | Telegram for HarmonyOS (this repository), package `com.hmcangjie.telegram` |
| Reference | Official Telegram iOS client, source `6ad963e5b6` |
| Test device | Huawei JUY-AL50, HarmonyOS 6.1.0.125 |
| Reference device | iPhone 17 Pro simulator, iOS 26.5 |
| Tested by | CJPLUK |

**Verdict: passed.** 279 of 287 test cases passed, a pass rate of 97.2%; the other 8 are pending development.

| Test cases | Passed | Pending development | Pass rate |
|---|---|---|---|
| 287 | 279 | 8 | 97.2% |

## 1. Scope

- **Goal**: confirm that the HarmonyOS app behaves the same as the official Telegram iOS client in the core usage scenarios.
- **Where the test cases come from**: 57 everyday scenarios; the rest were selected from the 538 user-visible entry points listed from the official iOS source. That gives 287 test cases.
- **Not included for now**: paid features (Premium, Stars, gifts), creator features (posting Stories, live streams, monetization), and debug or hidden-by-default options. These either touch sensitive areas such as payments and account security, or fall outside the core messaging experience, so they are not part of the development and test plan for this release.

## 2. Test Environment

| Item | HarmonyOS | iOS reference |
|---|---|---|
| Device | Huawei JUY-AL50 (real device) | iPhone 17 Pro simulator |
| OS | HarmonyOS 6.1.0.125 | iOS 26.5 |
| App | Telegram for HarmonyOS (`com.hmcangjie.telegram`) | Official Telegram iOS client (source `6ad963e5b6`) |
| Account | Test account H | Test account Q; groups, channels and bots created by a third test account |
| Network | Wi-Fi, connected directly to the Telegram production data centers | Same |
| Automation | `hdc` + `uitest` | `idb` |

## 3. Test Method

- The pass criteria of each test case describe only what a user can see. They were fixed before execution and not changed during it.
- The HarmonyOS device and the iOS simulator run the same test case, driven by scripts, with the screen recorded throughout and screenshots and app logs kept.
- The executor and an independent reviewer each judge the result from the screenshots and recordings; where they disagree, the case is decided again from the evidence.
- There are two results: **Passed**, every pass criterion is visible in the screenshots or recordings; **Pending development**, the feature is not finished yet or does not meet the pass criteria yet.

## 4. Results Overview

| Module | Coverage | Test cases | Passed | Pending development | Pass rate |
|---|---|---|---|---|---|
| [M01 Account and Launch](#m01) | Cold start, login persistence, sync on resume from background, recovery from network loss, log out and log back in | 5 | 5 | 0 | 100.0% |
| [M02 Chat List and Folders](#m02) | Chat row actions (pin / mute / archive / delete / read), folders, edit mode, new chat | 51 | 51 | 0 | 100.0% |
| [M03 Private Chats and Messages](#m03) | Text messages, input bar, formatting, stickers / emoji / GIFs, send options, attachment menu, message long-press menu | 43 | 39 | 4 | 90.7% |
| [M04 Media and Files](#m04) | Sending, viewing, and downloading photos, videos, files, voice messages, and round videos | 9 | 9 | 0 | 100.0% |
| [M05 Groups and Channels](#m05) | Group creation, group info, members, invite links, join / leave, channel browsing and comments | 28 | 26 | 2 | 92.9% |
| [M06 Contacts and Profiles](#m06) | Adding, deleting, and editing contacts; contact profile page; profile menu and edit page | 16 | 16 | 0 | 100.0% |
| [M07 Calls and Contacts Page](#m07) | Voice / video calls, call history, contacts page sorting and actions | 22 | 22 | 0 | 100.0% |
| [M08 Search and Saved Messages](#m08) | In-chat / global search across categories, Saved Messages | 16 | 15 | 1 | 93.8% |
| [M09 Notifications](#m09) | Background push, tapping a notification to open the chat, no alerts for muted chats | 3 | 3 | 0 | 100.0% |
| [M10 Settings](#m10) | Notifications and sounds, privacy and security, data and storage, appearance, language, devices, stickers and emoji, power saving, personal profile | 94 | 93 | 1 | 98.9% |
| **Total** |  | **287** | **279** | **8** | **97.2%** |

## 5. Test Cases

<a id="m01"></a>

### M01 Account and Launch (5 / 5)

| ID | Test case | Result |
|---|---|---|
| A4 | Recovery from network loss | Passed |
| A5 | Log out and log back in | Passed |
| A1 | Cold start into chat list | Passed |
| A2 | Login persistence | Passed |
| A3 | Sync on resume from background | Passed |

<a id="m02"></a>

### M02 Chat List and Folders (51 / 51)

| ID | Test case | Result |
|---|---|---|
| S1-52 | Leave group from list | Passed |
| S1-61 | Bulk delete in edit mode | Passed |
| B1 | Chat row information | Passed |
| B2 | Real-time unread count update | Passed |
| B3 | Scroll to load more | Passed |
| B4 | Pin / unpin | Passed |
| B5 | Mute / unmute | Passed |
| B6 | Mark as read | Passed |
| S1-01 | Edit mode | Passed |
| S1-02 | Reorder pinned chats in edit mode | Passed |
| S1-03 | New message entry point | Passed |
| S1-05 | New contact | Passed |
| S1-06 | New channel | Passed |
| S1-07 | Search contacts on the new message page | Passed |
| S1-09 | Chat list proxy button | Passed |
| S1-24 | Switch folders | Passed |
| S1-25 | Folder: edit | Passed |
| S1-26 | Folder: add chats | Passed |
| S1-27 | Folder: mark all as read | Passed |
| S1-29 | Folder: share | Passed |
| S1-30 | Delete folder | Passed |
| S1-31 | Folder: management entry point | Passed |
| S1-33 | Quick folder switching from the bottom bar | Passed |
| S1-34 | Open chat | Passed |
| S1-35 | Long-press to preview chat | Passed |
| S1-43 | Long-press to delete chat | Passed |
| S1-49 | Delete private chat for both sides | Passed |
| S1-53 | Swipe left to mute | Passed |
| S1-54 | Swipe left to delete | Passed |
| S1-55 | Swipe left to archive | Passed |
| S1-56 | Swipe right to mark read / unread | Passed |
| S1-57 | Swipe right to pin | Passed |
| S1-58 | Mark all as read in edit mode | Passed |
| S1-59 | Mark as read in edit mode | Passed |
| S1-63 | Open archive | Passed |
| S1-64 | Collapse archive | Passed |
| S1-65 | Pin archive back to the list | Passed |
| S1-68 | Pull down to reveal hidden archive | Passed |
| S1-28 | Folder: mute all / unmute all | Passed |
| S1-32 | Folder: reorder tabs | Passed |
| S1-37 | Long-press chat: remove from folder | Passed |
| S1-39 | Long-press chat: mark as unread | Passed |
| S1-44 | Long-press search result to join channel | Passed |
| S1-45 | Long-press search result to join group | Passed |
| S1-47 | Long-press search result to add contact | Passed |
| S1-50 | Delete confirmation: delete for me only | Passed |
| S1-51 | Delete confirmation: clear history | Passed |
| S1-60 | Edit mode: bulk archive | Passed |
| S1-62 | Undo after archive / delete | Passed |
| S1-66 | Archive row: mark all as read | Passed |
| S1-67 | Archive row: collapse / pin | Passed |

<a id="m03"></a>

### M03 Private Chats and Messages (39 / 43)

| ID | Test case | Result |
|---|---|---|
| S2-11 | Add contact from a non-contact chat | **Pending development** |
| S2-12 | Share my phone number | **Pending development** |
| S2-63 | Send silently | **Pending development** |
| S2-74 | Bot menu button | **Pending development** |
| S2-37 | Favorite stickers section | Passed |
| S3-16 | Multi-select messages | Passed |
| C1 | Send text | Passed |
| C2 | Receive text | Passed |
| C3 | Load message history | Passed |
| C4 | Reply to a message | Passed |
| C5 | Edit a message | Passed |
| C6 | Delete a message | Passed |
| C7 | Forward a message | Passed |
| C8 | Copy text | Passed |
| C9 | Emoji input | Passed |
| C10 | Links are tappable | Passed |
| S2-16 | Attachment button | Passed |
| S2-17 | Input field | Passed |
| S2-71 | Auto-delete timer | Passed |
| S2-73 | Bot reply keyboard | Passed |
| S2-01 | Tap the title to open the profile | Passed |
| S2-02 | Tap the avatar to open the profile (expanded avatar) | Passed |
| S2-18 | Bold text in the input field | Passed |
| S2-19 | Italic text in the input field | Passed |
| S2-24 | Mark input text as spoiler | Passed |
| S2-28 | Switch between emoji / sticker panels | Passed |
| S2-31 | Send a GIF from the GIF panel | Passed |
| S2-38 | Recently used stickers section | Passed |
| S2-48 | Filter GIFs by emoji category | Passed |
| S2-57 | Swipe up to lock recording | Passed |
| S2-58 | Swipe left to cancel recording | Passed |
| S2-59 | Switch between voice / video message modes | Passed |
| S2-70 | Scheduled message entry point | Passed |
| S2-72 | Bot command button (/) | Passed |
| S2-96 | Send a contact via attachment | Passed |
| S2-97 | Send music via attachment | Passed |
| S3-02 | Double-tap quick reaction | Passed |
| S3-03 | Swipe left to reply | Passed |
| S3-09 | Pin / unpin a message in a private chat | Passed |
| S3-10 | Save an image to the gallery | Passed |
| S3-21 | Read time of a private chat message | Passed |
| S3-23 | Voice message listened count (temporary basic group) | Passed |
| S3-25 | Cancel sending during upload | Passed |

<a id="m04"></a>

### M04 Media and Files (9 / 9)

| ID | Test case | Result |
|---|---|---|
| D1 | Send an image | Passed |
| D2 | View an image | Passed |
| D3 | Send a video | Passed |
| D4 | Play a video | Passed |
| D5 | Send a file | Passed |
| D6 | Download and open a file | Passed |
| D7 | Voice message | Passed |
| D8 | Stickers | Passed |
| D9 | Receive an image | Passed |

<a id="m05"></a>

### M05 Groups and Channels (26 / 28)

| ID | Test case | Result |
|---|---|---|
| S4-34 | Members tab in group profile | **Pending development** |
| S5-04 | View post comments in the discussion group | **Pending development** |
| E1 | Browse group messages | Passed |
| E2 | Post in a group | Passed |
| E3 | Group members and profile | Passed |
| E4 | Browse a channel | Passed |
| E5 | Join / leave a public channel | Passed |
| E6 | Create a group | Passed |
| S5-01 | Mute from the channel bottom bar | Passed |
| S4-01 | Open group profile from the group title / avatar | Passed |
| S4-02 | Members who read a group message | Passed |
| S4-05 | Mute / unmute from group profile | Passed |
| S4-12 | Open in-chat search from group profile | Passed |
| S4-13 | Group profile More menu | Passed |
| S4-23 | Display and copy the group description | Passed |
| S4-24 | Add members from group profile | Passed |
| S4-25 | Tap a member row to open the profile | Passed |
| S4-35 | Media tab in group profile | Passed |
| S4-36 | Files tab in group profile | Passed |
| S4-37 | Links tab in group profile | Passed |
| S4-38 | Voice tab in group profile | Passed |
| S4-39 | Audio tab in group profile | Passed |
| S4-40 | GIFs tab in group profile | Passed |
| S4-43 | Rename the group from group profile edit | Passed |
| S5-03 | Copy link of a channel post | Passed |
| S5-09 | Discuss in channel profile | Passed |
| S5-20 | Share link row in channel profile | Passed |
| S5-21 | Description row in channel profile | Passed |

<a id="m06"></a>

### M06 Contacts and Profiles (16 / 16)

| ID | Test case | Result |
|---|---|---|
| S6-05 | Profile page More: Change Wallpaper | Passed |
| S6-06 | Profile page More: Start Secret Chat | Passed |
| S6-07 | Profile page More: Share Contact | Passed |
| S6-27 | Contact edit: notes | Passed |
| S6-30 | Contact edit: Set Photo for &lt;name&gt; | Passed |
| S6-15 | Birthday row on profile page | Passed |
| F1 | Contact list | Passed |
| F2 | User profile | Passed |
| F3 | Start a chat from contacts | Passed |
| F4 | Edit own profile | Passed |
| F5 | Change avatar | Passed |
| S6-01 | Tap the other user's avatar to view it full size | Passed |
| S6-13 | Username row on profile page | Passed |
| S6-14 | Bio row on profile page | Passed |
| S6-20 | Add contact from profile page | Passed |
| S6-24 | Groups in common on profile page | Passed |

<a id="m07"></a>

### M07 Calls and Contacts Page (22 / 22)

| ID | Test case | Result |
|---|---|---|
| S8-08 | Long-press a contact to start a secret chat | Passed |
| H1 | Place a voice call | Passed |
| H2 | Answer a voice call | Passed |
| H3 | Video call | Passed |
| H4 | Group voice chat | Passed |
| S8-05 | Contacts permission entry point | Passed |
| S8-01 | Contact sorting | Passed |
| S8-02 | Add from contacts page | Passed |
| S8-03 | Contact search | Passed |
| S8-06 | Open a chat from contacts | Passed |
| S8-12 | Multi-select delete contacts | Passed |
| S8-14 | Long-press the Contacts tab to add | Passed |
| S8-15 | Call history filter | Passed |
| S8-16 | Edit call history | Passed |
| S8-19 | Create a call link | Passed |
| S8-21 | Call details | Passed |
| S8-22 | Swipe left to delete a call record | Passed |
| S8-23 | Ongoing group call | Passed |
| S8-26 | Show Calls tab | Passed |
| S8-07 | Long-press a contact to send a message | Passed |
| S8-11 | Long-press a contact to delete | Passed |
| S8-25 | Long-press the Calls tab to hide it | Passed |

<a id="m08"></a>

### M08 Search and Saved Messages (15 / 16)

| ID | Test case | Result |
|---|---|---|
| S9-11 | Channels search category | **Pending development** |
| G1 | Search chats | Passed |
| G2 | Search messages within a chat | Passed |
| G3 | Search public usernames | Passed |
| S9-14 | Media search category | Passed |
| S9-15 | Downloads search category | Passed |
| S9-16 | Links search category | Passed |
| S9-18 | Music search category | Passed |
| S9-19 | Voice search category | Passed |
| S9-20 | Search public posts by hashtag | Passed |
| S9-22 | Clear recent searches | Passed |
| S9-03 | Remove a forwarded message from Saved Messages | Passed |
| S9-17 | Files search category | Passed |
| S9-23 | Global message search scope filter | Passed |
| S9-30 | Jump from a search result to the original message | Passed |
| S9-33 | Forward a search result | Passed |

<a id="m09"></a>

### M09 Notifications (3 / 3)

| ID | Test case | Result |
|---|---|---|
| I1 | Background push | Passed |
| I2 | Tap a notification to open the chat | Passed |
| I3 | No alerts for muted chats | Passed |

<a id="m10"></a>

### M10 Settings (93 / 94)

| ID | Test case | Result |
|---|---|---|
| S7-66 | Prompt when notification permission is off | **Pending development** |
| S7-117 | Tap to switch to the next item | Passed |
| S7-95 | Auto-save media from private chats | Passed |
| S7-08 | Username entry in Settings | Passed |
| S7-16 | Add account | Passed |
| S7-44 | Profile birthday | Passed |
| J1 | Settings home page | Passed |
| J2 | Notification settings persist | Passed |
| J3 | Privacy settings | Passed |
| J4 | Switch language | Passed |
| J5 | Clear cache | Passed |
| J6 | Active devices | Passed |
| S7-01 | Edit profile entry in Settings | Passed |
| S7-02 | My QR code | Passed |
| S7-03 | Settings search | Passed |
| S7-15 | Switch accounts from the account list | Passed |
| S7-17 | My profile | Passed |
| S7-18 | Proxy entry in Settings | Passed |
| S7-20 | Open Saved Messages from Settings | Passed |
| S7-21 | Open call history from Settings | Passed |
| S7-24 | Open folders from Settings | Passed |
| S7-25 | Open notifications from Settings | Passed |
| S7-26 | Open privacy from Settings | Passed |
| S7-27 | Data and storage page | Passed |
| S7-28 | Open appearance from Settings | Passed |
| S7-29 | Power saving page | Passed |
| S7-30 | Open language from Settings | Passed |
| S7-39 | Telegram FAQ | Passed |
| S7-40 | Telegram Features | Passed |
| S7-48 | Personal channel in profile | Passed |
| S7-53 | Group notification settings | Passed |
| S7-54 | Channel notification settings | Passed |
| S7-56 | Reaction notifications | Passed |
| S7-57 | In-app sounds | Passed |
| S7-59 | In-app previews | Passed |
| S7-60 | Show names on the lock screen | Passed |
| S7-63 | New contact notifications | Passed |
| S7-72 | Default auto-delete timer | Passed |
| S7-74 | Phone number visibility | Passed |
| S7-76 | Profile photo visibility | Passed |
| S7-77 | Bio visibility | Passed |
| S7-79 | Birthday visibility | Passed |
| S7-80 | Saved music visibility | Passed |
| S7-81 | Link in forwarded messages | Passed |
| S7-85 | Invitation permissions | Passed |
| S7-88 | Data settings | Passed |
| S7-91 | Network usage | Passed |
| S7-93 | Auto-download over Wi-Fi | Passed |
| S7-96 | Save group chat media to the gallery | Passed |
| S7-97 | Save channel media to the gallery | Passed |
| S7-100 | Save edited photos | Passed |
| S7-101 | Pause music while recording | Passed |
| S7-102 | Raise to listen | Passed |
| S7-106 | Switch color theme | Passed |
| S7-107 | Chat background | Passed |
| S7-111 | Text size | Passed |
| S7-112 | Bubble corner radius | Passed |
| S7-113 | Animations entry | Passed |
| S7-118 | Translate button | Passed |
| S7-120 | Do Not Translate languages | Passed |
| S7-123 | Delete a custom language | Passed |
| S7-124 | Create a folder | Passed |
| S7-128 | Add a custom folder | Passed |
| S7-131 | Current device details | Passed |
| S7-133 | Other device details | Passed |
| S7-152 | Autoplay videos | Passed |
| S7-153 | GIF autoplay | Passed |
| S7-156 | Interface effects | Passed |
| S7-157 | Extended background time | Passed |
| S7-42 | Change name | Passed |
| S7-46 | Change username | Passed |
| S7-50 | Edit profile: add account | Passed |
| S7-58 | In-app vibration | Passed |
| S7-61 | Badge includes channels | Passed |
| S7-62 | Badge counts messages | Passed |
| S7-64 | Reset all notifications | Passed |
| S7-65 | Notifications from multiple accounts | Passed |
| S7-82 | Call privacy | Passed |
| S7-89 | Link opening method | Passed |
| S7-94 | Reset auto-download settings | Passed |
| S7-98 | Use less data for calls | Passed |
| S7-104 | Proxy entry on the data page | Passed |
| S7-105 | Appearance: color theme list | Passed |
| S7-109 | Night mode toggle | Passed |
| S7-110 | Auto-night theme | Passed |
| S7-114 | Open stickers and emoji from Appearance | Passed |
| S7-122 | Language search | Passed |
| S7-125 | Folder settings: edit a folder | Passed |
| S7-126 | Folder settings: reorder and delete | Passed |
| S7-127 | Add a recommended folder | Passed |
| S7-151 | Power saving battery threshold | Passed |
| S7-154 | Sticker animations | Passed |
| S7-155 | Emoji animations | Passed |
| S7-158 | Preload media | Passed |

## 6. Conclusion

- 279 of 287 test cases passed, a pass rate of 97.2%; 8 are pending development.
- Test cases pending development: S2-11 Add contact from a non-contact chat; S2-12 Share my phone number; S2-63 Send silently; S2-74 Bot menu button; S4-34 Members tab in group profile; S5-04 View post comments in the discussion group; S9-11 Channels search category; S7-66 Prompt when notification permission is off.
- Verdict: passed.
