# Echo Messenger -- E2E Test Plan

Last updated: 2026-04-03

## Test Accounts
- User A: `tester_0283a` / `TestPass123`
- User B: `tester_0283b` / `TestPass123`
- Contact relationship established between them

## Phase 1: Bug Verification (re-test known issues)

### P1.1 Conversation stays selected on incoming message
1. User A opens chat with User B
2. User B sends a message via WebSocket
3. **Verify**: Chat panel stays open (does NOT revert to "Select a conversation")
4. **Verify**: New message appears at bottom
5. **Verify**: Sidebar preview updates

### P1.2 Encryption state stability
1. Open a DM conversation, note encryption state (on/off)
2. Click Groups tab in sidebar
3. Click Chats tab, re-open same conversation
4. **Verify**: Encryption state is unchanged

### P1.3 Emoji picker dismiss
1. Click + button -> Emoji
2. Press Escape
3. **Verify**: Emoji picker closes
4. **Verify**: Message input has focus (type text, verify it appears in input)

### P1.4 Hover actions visible
1. Move mouse over a sent message bubble
2. **Verify**: Action bar appears (copy, react, reply, edit, delete icons)
3. Move mouse over a received message bubble
4. **Verify**: Action bar appears (copy, react, reply icons -- no edit/delete)

## Phase 2: Encryption End-to-End

### P2.1 Toggle encryption on
1. Open a DM where encryption is OFF
2. Click lock icon in chat header
3. **Verify**: Confirmation dialog appears
4. Confirm -> **Verify**: Green "Encryption enabled" divider appears
5. **Verify**: Banner changes to "Messages are end-to-end encrypted"

### P2.2 Send encrypted message
1. With encryption ON, type a message and send
2. **Verify**: Message shows lock icon
3. Have User B reply
4. **Verify**: User A can read the reply (decryption works)

### P2.3 Toggle encryption off
1. Click lock icon again
2. Confirm toggle off
3. **Verify**: Banner changes back to plaintext warning
4. Send a message -> **Verify**: No lock icon

### P2.4 Navigate and verify state persists
1. Click Groups tab
2. Click Chats tab, re-open conversation
3. **Verify**: Encryption state matches what was set in P2.3

## Phase 3: Image Pipeline

### P3.1 Upload image via File picker
1. Click + button -> File
2. Select a .png or .jpg image
3. **Verify**: Discord-style preview bar appears above input
4. **Verify**: Preview shows: thumbnail, filename, upload progress/status
5. Press Enter
6. **Verify**: Image renders inline in chat for sender

### P3.2 Receiver sees image
1. User B opens the conversation
2. **Verify**: Image loads and renders inline (not broken/401)
3. **Verify**: No JWT token visible in message text

### P3.3 Image viewer
1. Click on the sent image
2. **Verify**: Fullscreen viewer opens
3. **Verify**: Pinch/scroll zoom works
4. **Verify**: Download button present
5. Click outside or press ESC to close viewer

### P3.4 Ctrl+V paste image
1. Copy an image to clipboard (screenshot or copy from browser)
2. Focus chat input, press Ctrl+V
3. **Verify**: Preview bar appears with pasted image thumbnail
4. **Verify**: "Uploading..." then "Ready to send"
5. Press Enter -> **Verify**: Image sends and renders inline

### P3.5 Text paste still works after image paste
1. Copy text to clipboard
2. Focus chat input, Ctrl+V
3. **Verify**: Text is pasted normally (no image picker interference)

### P3.6 Cancel attachment
1. Paste or pick an image
2. **Verify**: Preview bar appears
3. Click X button on preview bar
4. **Verify**: Preview clears, no attachment sent
5. Press ESC with preview showing -> **Verify**: Same result

### P3.7 GIF received by other user
1. User A sends a GIF
2. User B opens conversation
3. **Verify**: GIF renders inline for User B

## Phase 4: Message Actions

### P4.1 Edit message
1. Hover over own sent message
2. Click edit (pencil) icon
3. **Verify**: Input field shows original text with edit indicator
4. Modify text, press Enter
5. **Verify**: Message updates in-place with "(edited)" marker
6. **Verify**: Other user sees the edited text

### P4.2 Delete message
1. Hover over own sent message
2. Click delete (trash) icon
3. **Verify**: Confirmation dialog appears
4. Confirm -> **Verify**: Message shows as deleted
5. **Verify**: Other user sees deletion

### P4.3 Reply to message
1. Hover over any message
2. Click reply (arrow) icon
3. **Verify**: Reply preview appears above input with quoted text
4. Type reply text, press Enter
5. **Verify**: Reply shows with quoted context block above it

### P4.4 React to message
1. Hover over any message
2. Click react (smiley+) icon
3. **Verify**: Reaction picker overlay appears above the message
4. Click an emoji
5. **Verify**: Reaction badge appears below the message
6. **Verify**: Other user sees the reaction

### P4.5 Copy message text
1. Hover over a text message
2. Click copy icon
3. **Verify**: Toast shows "Copied to clipboard"
4. Paste in input field -> **Verify**: Correct text pasted

## Phase 5: Scroll and History

### P5.1 Auto-scroll to bottom on open
1. Send 20+ messages in a conversation
2. Navigate away then back to the conversation
3. **Verify**: Chat scrolls to the newest message at bottom

### P5.2 Scroll up loads older messages
1. In a conversation with many messages, scroll to top
2. **Verify**: Loading indicator appears
3. **Verify**: Older messages load above existing ones

### P5.3 New message while scrolled up
1. Scroll up to read old messages
2. Have User B send a new message
3. **Verify**: You are NOT force-scrolled to bottom (reading position preserved)
4. **Verify**: Unread indicator or "new messages" banner appears

### P5.4 Auto-scroll on own send
1. Type and send a message
2. **Verify**: Chat scrolls to show your new message at bottom

### P5.5 Shift+Enter multiline
1. Type "Line one"
2. Press Shift+Enter
3. Type "Line two"
4. Press Enter (without Shift)
5. **Verify**: Message sends with two lines
6. **Verify**: Message renders with line break preserved

## Phase 6: State Resilience

### P6.1 JWT token refresh (15+ min)
1. Log in and open a conversation
2. Wait 16 minutes (JWT access token expires at 15 min)
3. Send a message
4. **Verify**: Message sends successfully (transparent token refresh)
5. **Verify**: No 401 errors in console

### P6.2 Logout and re-login
1. Settings -> Log out
2. **Verify**: Redirected to login page
3. Log back in
4. **Verify**: Conversations load, history present
5. **Verify**: WebSocket connects, real-time messaging works

### P6.3 Browser refresh
1. While in a conversation, press F5 / Ctrl+R
2. **Verify**: App reloads with login preserved (auto-login from refresh token)
3. **Verify**: Last conversation selection may reset (acceptable)

### P6.4 Narrow viewport (responsive)
1. Resize browser to 768px width
2. **Verify**: Layout switches to single-panel mode
3. **Verify**: Back button appears to return to conversation list
4. **Verify**: Conversation list and chat panel are not overlapping

### P6.5 Browser back/forward
1. Navigate: Chats -> open conversation -> Groups tab -> Settings
2. Press browser Back button
3. **Verify**: Returns to previous view without crash

## Phase 7: Group Chat

### P7.1 Create group
1. Click Groups tab -> Create Group
2. Enter group name, submit
3. **Verify**: Group appears in sidebar with #general and lounge channels
4. **Verify**: Default channels created

### P7.2 Send message in group
1. Open the new group
2. Click #general channel
3. Type a message, send
4. **Verify**: Message appears in the channel

### P7.3 Switch channels
1. Click #second or another text channel
2. **Verify**: Message area switches to that channel's messages
3. Click back to #general
4. **Verify**: Original messages visible

### P7.4 Add member
1. Open group info (click (i) icon)
2. Click Add Member
3. Select a contact
4. **Verify**: Member appears in member list
5. **Verify**: Added user can see the group

### P7.5 Voice channel
1. Click the lounge chip
2. **Verify**: Voice dock appears above user status bar
3. **Verify**: Lounge chip shows as selected/active
4. Click lounge chip again (or Leave in dock)
5. **Verify**: Voice dock disappears
6. **Verify**: Lounge chip deselects

## Phase 8: Contacts

### P8.1 Send contact request
1. Click add-contact icon in sidebar header
2. Search for a username
3. Send request
4. **Verify**: Request appears as pending on receiver's side

### P8.2 Accept contact request
1. Log in as the receiver
2. Go to Contacts tab
3. **Verify**: Pending request visible
4. Accept -> **Verify**: Contact appears in contacts list

### P8.3 Start DM from contacts
1. Click the "Message" button next to a contact
2. **Verify**: DM conversation opens

## Phase 9: Read Receipts and Status

### P9.1 Message status icons
1. Send a message
2. **Verify**: Shows clock icon (sending) briefly
3. **Verify**: Changes to single check (sent)
4. When other user's client receives it -> **Verify**: Gray double check (delivered)
5. When other user reads it -> **Verify**: Green double check (read)

### P9.2 Read receipts disabled
1. User B: Settings -> Privacy -> toggle "Send Read Receipts" OFF
2. User A sends a message
3. User B opens the conversation (reads it)
4. **Verify**: User A sees gray double check (delivered) but NOT green (read)

### P9.3 Privacy: block unencrypted DMs
1. User B: Settings -> Privacy -> toggle "Allow Unencrypted Direct Messages" OFF
2. User A (with encryption off) tries to send a message
3. **Verify**: Warning toast appears, message not sent

## Phase 10: Edge Cases

### P10.1 Long message (2000+ characters)
1. Paste a very long text
2. Send
3. **Verify**: Renders properly, doesn't overflow or break layout

### P10.2 Special characters
1. Send: `<script>alert('xss')</script>`
2. **Verify**: Renders as text, no script execution
3. Send emoji-heavy message: `🔥🎉👍🎮🎵🎨🔬📰🎲🍕`
4. **Verify**: All emoji render correctly

### P10.3 Empty conversation
1. New user with no conversations
2. **Verify**: "No conversations yet" empty state visible
3. **Verify**: "Start a new chat" CTA works

### P10.4 Rapid messages
1. Send 10 messages in quick succession
2. **Verify**: All 10 appear in order
3. **Verify**: No duplicates
4. **Verify**: Scroll follows correctly

---

## Screenshot Naming Convention
`{NN}-{phase}-{description}.png`
Example: `35-p3-image-upload-preview.png`

## How to Run
```bash
# Create test accounts (one-time)
./scripts/seed_demo_data.sh

# Start Playwright MCP (in Claude Code with --browser chromium)
# Navigate to https://echo-messenger.us
# Follow phases in order
```
