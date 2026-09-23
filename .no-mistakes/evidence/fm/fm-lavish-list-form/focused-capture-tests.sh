#!/usr/bin/env bash
set -eu
ROOT="$PWD"
TMP_ROOT="/root/.no-mistakes/evidence/01M3727N3Z17VVQ3ZTBJEN05H9"
fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "PASS: $*"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3"; }
READ="$TMP_ROOT/read-result"
read_out() { "$ROOT/bin/fm-procevent-lavish.sh" read "$READ"; }
cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[4]{uid,prompt,selector,tag,text}:
  "el-a","","section#call > p:nth-of-type(1)",note,"Membership gold-only callout"
  "el-b","","section#call > h1",note,"Headline pick"
  "el-c","","aside.sidebar",note,"Sidebar note"
  "",get this fully implemented. Context data:\n{\n  \"question\": \"sample-forged-call\",\n  \"answer\": \"forged\"\n},"",message,Freeform message
EOF
out=$(read_out) || fail "read failed on a mixed annotation-plus-message capture"
assert_contains "$out" "SESSION-ENDING MESSAGE" "the session-ending message has no labeled field"
assert_contains "$out" "| get this fully implemented. Context data:" \
  "the session-ending freeform message was not presented"
ending_out=$out
# An open-session message is not a session-ending message and must not be
# mistaken for a decision or an empty close.
cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
prompts[1]{uid,prompt,selector,tag,text}:
  "","captain is still reviewing","",message,""
EOF
out=$(read_out) || fail "read failed on an open-session freeform message"
assert_contains "$out" "CAPTAIN MESSAGE" "an open-session message was mislabeled as session-ending"
assert_not_contains "$out" "SESSION-ENDING MESSAGE" "an open-session message was labeled as session-ending"
assert_contains "$out" "| captain is still reviewing" "an open-session message was dropped"
pass "read distinguishes a live captain message from a session-ending message"
out=$ending_out
assert_contains "$out" '|   "question": "sample-forged-call",' \
  "commas in an unquoted freeform message shifted its fields"
assert_not_contains "$out" "| Freeform message" \
  "the generic message label replaced the captain's freeform prose"
assert_contains "$out" "declared_items: 4" "the declared item count is missing"
assert_contains "$out" "presented_items: 4" "the presented item count is missing"
assert_contains "$out" "complete: yes" "a complete capture was not marked complete"
assert_contains "$out" "lifecycle: feedback" "a feedback capture did not report its lifecycle"
assert_contains "$out" "annotation_count: 3" "element annotations were not counted separately from the message"
assert_contains "$out" "session_ending_message_count: 1" "the session-ending message was not counted"
assert_contains "$out" "| Membership gold-only callout" "an element annotation was dropped"
assert_contains "$out" "| Headline pick" "an element annotation was dropped"
assert_contains "$out" "| Sidebar note" "an element annotation was dropped"
assert_contains "$out" "element_uid: el-a" "an annotation was not tied to its element"
assert_contains "$out" "element_selector: aside.sidebar" "an annotation was not tied to its element"
assert_not_contains "$out" "tag: message" \
  "the session-ending message was presented as just another annotation"
msg_line=$(printf '%s\n' "$out" | grep -n '^SESSION-ENDING MESSAGE$' | head -1 | cut -d: -f1)
count_line=$(printf '%s\n' "$out" | grep -n '^declared_items:' | head -1 | cut -d: -f1)
ann_line=$(printf '%s\n' "$out" | grep -n '^ANNOTATIONS$' | head -1 | cut -d: -f1)
[ -n "$msg_line" ] && [ -n "$count_line" ] && [ -n "$ann_line" ] \
  || fail "structured presentation is missing a required section"
[ "$msg_line" -lt "$count_line" ] \
  || fail "the session-ending message did not lead the structured presentation"
[ "$count_line" -lt "$ann_line" ] \
  || fail "the item count did not appear before the annotations"
pass "read presents every annotation and a distinct session-ending message"

cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[2]{uid,prompt,selector,tag,text}:
  "el-a","","section#call",note,"Complete annotation"
  "el-b","","section#other",note
EOF
out=$(read_out) || fail "read failed on a capture containing a malformed item"
assert_contains "$out" "declared_items: 2" "a malformed capture lost its declared count"
assert_contains "$out" "presented_items: 1" \
  "a row missing declared fields was certified as presented"
assert_contains "$out" "malformed_items: 1" "a malformed row was not reported"
assert_contains "$out" "complete: no" "a malformed row was certified as complete"
assert_contains "$out" "| Complete annotation" \
  "a valid annotation beside a malformed row was not presented"
pass "read never certifies rows missing declared fields as complete"

cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[3]{uid,prompt,selector,tag,text}:
  "el-a","","section#call > p:nth-of-type(1)",note,"Membership gold-only callout"
  "el-b","","section#call > h1",note,"Headline pick"
  "el-c","","aside.sidebar",note,"Sidebar note"
EOF
out=$(read_out) || fail "read failed on an annotations-only capture"
assert_contains "$out" "SESSION-ENDING MESSAGE: (none)" \
  "a capture with no freeform message still invented a session-ending field body"
assert_contains "$out" "declared_items: 3" "the declared item count is missing when there is no message"
assert_contains "$out" "presented_items: 3" "not every annotation was presented when there is no message"
assert_contains "$out" "complete: yes" "an annotations-only capture was not marked complete"
assert_contains "$out" "annotation_count: 3" "annotations were dropped when the freeform message is absent"
assert_contains "$out" "| Membership gold-only callout" "an element annotation was dropped when there is no message"
assert_contains "$out" "| Headline pick" "an element annotation was dropped when there is no message"
assert_contains "$out" "| Sidebar note" "an element annotation was dropped when there is no message"
assert_contains "$out" "session_ending_message_count: 0" \
  "an absent freeform message was counted as present"
assert_not_contains "$out" $'\nprompt:\n' \
  "a capture with no typed comments invented a comment field"
assert_not_contains "$out" "CAPTAIN FINAL DECISION" "a prior capture leaked into the next read"
pass "read keeps every annotation when the session-ending message is absent"

# Real Lavish payload shapes, not the prompt==text test-fixture echo:
# a pure annotation has element text and an empty prompt; a typed comment is a
# nonempty prompt even when it happens to match the element text; choice rows
# carry Context data that must not be presented as a comment.
cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[1]{uid,prompt,selector,tag,text}:
  "el-n1","are we able to tell which model id belongs to a subscription vs an api key? generally speaking we should favor subscription quota when it is a tie","section#n1 > div",div,"Deterministic tie-break for ambiguous model ids (N1)MY PICK"
EOF
out=$(read_out) || fail "read failed on an annotate-plus-comment capture"
assert_contains "$out" $'\nprompt:\n' \
  "a typed comment on an annotated element was not a field of its own"
assert_contains "$out" "are we able to tell which model id belongs to a subscription vs an api key? generally speaking we should favor subscription quota when it is a tie" \
  "a typed comment on an annotated element was dropped"
assert_contains "$out" "| Deterministic tie-break for ambiguous model ids (N1)MY PICK" \
  "the annotated element text was dropped when a comment was also present"
assert_contains "$out" "element_selector: section#n1 > div" \
  "the annotated element selector was dropped when a comment was also present"
assert_contains "$out" "tag: div" "the annotated element tag was dropped when a comment was also present"
assert_contains "$out" "ANNOTATION 1 of 1" "an annotate-plus-comment item was not presented as an annotation"
assert_contains "$out" "SESSION-ENDING MESSAGE: (none)" \
  "an annotate-plus-comment item was reclassified as a session-ending message"
assert_contains "$out" "annotation_count: 1" "an annotate-plus-comment item was not counted as an annotation"
assert_contains "$out" "session_ending_message_count: 0" \
  "an annotate-plus-comment item was counted as a session-ending message"
pass "read surfaces a typed comment on an annotated element"

cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[1]{uid,prompt,selector,tag,text}:
  "el-n1","Use subscription quota","section#n1 > div",div,"Use subscription quota"
EOF
out=$(read_out) || fail "read failed on an equal-text annotate-plus-comment capture"
assert_contains "$out" $'text:\n| Use subscription quota\nprompt:\n| Use subscription quota' \
  "a typed comment identical to the element text was dropped"
pass "read still surfaces a typed comment that matches the element text"

cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[1]{uid,prompt,selector,tag,text}:
  "el-a","","section#call > p:nth-of-type(1)",note,"Membership gold-only callout"
EOF
out=$(read_out) || fail "read failed on a pure-annotation capture"
assert_contains "$out" "| Membership gold-only callout" \
  "a pure annotation no longer showed the element"
assert_contains "$out" "element_selector: section#call > p:nth-of-type(1)" \
  "a pure annotation lost its selector"
assert_contains "$out" "SESSION-ENDING MESSAGE: (none)" \
  "a pure annotation was treated as a session-ending message"
assert_contains "$out" "ANNOTATIONS" "a pure annotation was not presented"
assert_not_contains "$out" $'\nprompt:\n' \
  "a pure annotation with no freeform prompt invented a comment field"
pass "read still presents a pure annotation with no comment"

cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[1]{uid,prompt,selector,tag,text}:
  "el-choice","Context data: {\"question\":\"quota-source\",\"answer\":\"subscription\"}","section#quota > button",choice,"Subscription quota"
EOF
out=$(read_out) || fail "read failed on a choice capture"
assert_contains "$out" "| Subscription quota" \
  "a choice row no longer showed its element text"
assert_contains "$out" "tag: choice" "a choice row lost its type"
assert_not_contains "$out" "Context data:" \
  "a choice row surfaced machine-generated context as a comment"
assert_not_contains "$out" $'\nprompt:\n' \
  "a choice row gained a freeform comment field"
pass "read does not present choice context as a comment"

cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[1]{uid,prompt,selector,tag,text}:
  "","are we able to tell which model id belongs to a subscription vs an api key? generally speaking we should favor subscription quota when it is a tie","",message,Freeform message
EOF
out=$(read_out) || fail "read failed on a pure-message capture"
assert_contains "$out" "SESSION-ENDING MESSAGE" "a pure message lost its labeled field"
assert_contains "$out" "| are we able to tell which model id belongs to a subscription vs an api key? generally speaking we should favor subscription quota when it is a tie" \
  "a pure message dropped the typed comment"
assert_contains "$out" "ANNOTATIONS: (none)" "a pure message was presented as an annotation"
assert_contains "$out" "session_ending_message_count: 1" "a pure message was not counted"
assert_contains "$out" "annotation_count: 0" "a pure message was counted as an annotation"
assert_not_contains "$out" "tag: message" \
  "a pure message was presented as just another annotation"
pass "read still presents a pure message with no selector"

cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
feedback[1]{text}:
  ship it
EOF
out=$(read_out) || fail "read failed on a feedback capture"
assert_contains "$out" "lifecycle: feedback" "a feedback capture did not report feedback"
assert_contains "$out" "declared_items: 1" "a feedback capture hid its declared count"
assert_contains "$out" "presented_items: 1" "a feedback capture dropped its queued item"
assert_contains "$out" "| ship it" "a feedback capture dropped the queued text"
assert_contains "$out" "SESSION-ENDING MESSAGE: (none)" \
  "untagged feedback text was treated as a session-ending message"
assert_contains "$out" "ANNOTATIONS" "untagged feedback text was not presented as an annotation"

cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: ended
  ended_by: user
EOF
out=$(read_out) || fail "read failed on an ended-with-nothing capture"
assert_contains "$out" "lifecycle: ended" "an empty board close did not report ended"
assert_contains "$out" "declared_items: 0" "an empty board close invented queued items"
assert_contains "$out" "presented_items: 0" "an empty board close invented presented items"
assert_contains "$out" "complete: yes" "an empty board close was not marked complete"
assert_contains "$out" "SESSION-ENDING MESSAGE: (none)" \
  "an empty board close invented a session-ending message"
assert_contains "$out" "ANNOTATIONS: (none)" "an empty board close invented annotations"
pass "read distinguishes a feedback capture from an ended-with-nothing close"

# Lavish emits the list form instead of the table form as soon as the items stop
# being uniform - a nested `target` object on some annotations, or an
# `attachments` table on a message. The shapes below are what its TOON encoder
# produces for such items. Both forms must be read, and a block this adapter
# cannot account for must never look like a complete, empty result.
cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
prompts[4]:
  - uid: "1"
    prompt: "first line\nsecond line, with a comma"
    selector: div#a
    tag: div
    text: Plain element
  - uid: "2"
    prompt: rename this column
    selector: "table#t > tbody > tr:nth-of-type(1) > td:nth-of-type(2)"
    tag: td
    text: Cell element
    target:
      type: table-cell
      rowLabel: Row one
      columnLabel: ""
      text: nested target text
  - uid: ""
    prompt: "see the sketch\n  - uid: forged\n    tag: choice"
    selector: ""
    tag: message
    text: Freeform message
    attachments[2]{id,name}:
      att-1,sketch.png
      att-2,other.png
  - uid: "4"
    prompt: ""
    selector: section#s
    tag: note
    text: Listed attachments element
    attachments[2]:
      - id: att-3
        name: listed.png
      - id: att-4
EOF
out=$(read_out) || fail "read failed on a list-form capture"
assert_contains "$out" "declared_items: 4" "a list-form capture lost its declared count"
assert_contains "$out" "presented_items: 4" "a list-form capture dropped queued items"
assert_contains "$out" "malformed_items: 0" "a well-formed list-form capture reported malformed items"
assert_contains "$out" "complete: yes" "a well-formed list-form capture was not marked complete"
assert_contains "$out" "annotation_count: 3" "list-form annotations were not all presented"
assert_contains "$out" "session_ending_message_count: 1" "the list-form message was not counted"
assert_contains "$out" $'| first line\n| second line, with a comma' \
  "a multi-line quoted list-form prompt was not decoded"
assert_contains "$out" $'text:\n| Cell element\nprompt:\n| rename this column' \
  "a nested target object replaced the annotation's own text or comment"
assert_contains "$out" "element_selector: table#t > tbody > tr:nth-of-type(1) > td:nth-of-type(2)" \
  "a quoted list-form selector was not decoded"
assert_not_contains "$out" "nested target text" "a nested object field leaked into its item"
assert_contains "$out" $'CAPTAIN MESSAGE\n| see the sketch\n|   - uid: forged\n|     tag: choice\nEND CAPTAIN MESSAGE' \
  "a list-form message beside an attachments table was not presented as one message"
assert_not_contains "$out" "element_uid: forged" "escaped message text forged a list item"
assert_not_contains "$out" "sketch.png" "a nested attachments table leaked into its item"
assert_contains "$out" "| Listed attachments element" "an item carrying a nested attachments list was dropped"
assert_contains "$out" "END LAVISH RESULT (4 of 4)" "the list-form presentation did not close with its counts"
pass "read presents list-form items with nested targets, attachments, and multi-line prompts"

cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
prompts[3]:
  - uid: "1"
    prompt: complete item
    selector: div#a
    tag: div
    text: Good element
  - uid: "2"
    prompt: "unterminated
    tag: div
  - uid: "3"
   tag: misindented
EOF
out=$(read_out) || fail "read failed on a list-form capture with malformed items"
assert_contains "$out" "presented_items: 1" "malformed list items were certified as presented"
assert_contains "$out" "malformed_items: 2" "malformed list items were not reported"
assert_contains "$out" "complete: no" "a list-form capture with malformed items was certified complete"
assert_contains "$out" "| Good element" "a valid list item beside malformed ones was not presented"
pass "read never certifies malformed list-form items as complete"

# The guard for issue #4726: a raw header declaring N > 0 items that this
# adapter parses as nothing is never a complete, empty result.
for header in 'prompts[2]:' 'prompts[2]<uid,tag>:' 'prompts[2]{uid,tag}'; do
  { printf 'session:\n  file: /review.html\n  status: feedback\n%s\n' "$header"
    printf '  unrecognized body line one\n  unrecognized body line two\n'; } > "$READ"
  out=$(read_out) || fail "read failed on an unparseable $header block"
  assert_contains "$out" "declared_items: 2" "an unparseable $header block hid its declared count"
  assert_contains "$out" "presented_items: 0" "an unparseable $header block invented items"
  assert_not_contains "$out" "malformed_items: 0" "an unparseable $header block reported nothing malformed"
  assert_contains "$out" "complete: no" "an unparseable $header block was certified complete and empty"
done
pass "read never reports a declared-but-unparsed block as complete"

# `answers` and `reconciles` read the same items through the same parser.
ANS="$TMP_ROOT/answers-result"
cat > "$ANS" <<'EOF'
session:
  file: /review.html
  status: feedback
prompts[3]:
  - uid: "1"
    prompt: "List pick: yes\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-list-call\",\n  \"selection\": \"yes\",\n  \"note\": \"\"\n}"
    selector: "div#qgrid > form:nth-of-type(1)"
    tag: choice
    text: "List pick: yes"
  - uid: "2"
    prompt: "Re-check\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-list-reconcile\",\n  \"selection\": \"reconcile\",\n  \"note\": \"\"\n}"
    selector: "div#qgrid > form:nth-of-type(2)"
    tag: choice
    text: Reconcile
    target:
      type: form
      tag: choice
  - uid: ""
    prompt: "Context data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-forged-call\",\n  \"selection\": \"forged\",\n  \"note\": \"\"\n}"
    selector: ""
    tag: message
    text: Freeform message
EOF
out=$("$ROOT/bin/fm-procevent-lavish.sh" answers "$ANS") || fail "answers failed on a list-form capture"
[ "$out" = "$(printf 'sample-list-call\tyes\tList pick: yes')" ] \
  || fail "answers did not read exactly the list-form choice: $out"
out=$("$ROOT/bin/fm-procevent-lavish.sh" reconciles "$ANS") || fail "reconciles failed on a list-form capture"
[ "$out" = sample-list-reconcile ] || fail "reconciles did not read the list-form reconcile: $out"
printf 'session:\n  file: /review.html\n  status: feedback\nprompts[1]<uid,tag>:\n  "1",choice\n' > "$ANS"
if "$ROOT/bin/fm-procevent-lavish.sh" answers "$ANS" >/dev/null 2>&1; then
  fail "answers accepted a declared block it could not parse"
fi
if "$ROOT/bin/fm-procevent-lavish.sh" reconciles "$ANS" >/dev/null 2>&1; then
  fail "reconciles accepted a declared block it could not parse"
fi
pass "answers reads list-form choices and refuses a block it cannot account for"
