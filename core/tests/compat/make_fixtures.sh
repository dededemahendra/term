#!/bin/sh
# Regenerates the hand written fixtures. Each one exercises a family of
# escape sequences; the expected screen for each is listed in the
# implementation plan, Task 14.
set -eu
cd "$(dirname "$0")"

printf 'line one\r\nline two\r\n\033[3;5Hmoved\033[1;1H\033[2Cx\033[24;1Hbottom' > cursor.in
printf '\033[31mred\033[0m plain \033[1;44mbold on blue\033[m\r\n\033[38;2;1;2;3mtrue\033[38:5:200m 256\033[m' > colours.in
printf 'primary\033[?1049h\033[Halt text\033[?1049l back' > altscreen.in
printf '\033[2;4r\033[2;1Ha\r\nb\r\nc\r\nd\r\ne\033[r' > scrollregion.in
printf 'a%.0s' $(seq 1 100) > wrap.in
printf '日本語 ok\r\nnaïve 👍🏽 ❤️ end' > utf8.in
printf 'abcdef\033[3G\033[2@\033[6G\033[P\033[2K\033[Hgone\033[1;3H\033[K' > editing.in
