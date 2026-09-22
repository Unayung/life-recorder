# The always-on side, on omarchy

The receiver, the desktop meeting capture and the ten-minute summary run as systemd user
services on the Linux desktop. They are kept here so the machine can be rebuilt from the repo;
install them with:

    cp deploy/omarchy/*.service deploy/omarchy/*.timer ~/.config/systemd/user/
    cp deploy/omarchy/summarize.sh ~/.local/share/life-recorder/
    systemctl --user daemon-reload
    systemctl --user enable --now life-recorder-receiver life-recorder-desktop life-recorder-summary.timer
    loginctl enable-linger "$USER"

What is deliberately not here: the token, the certificate and key, the inbox, the transcripts,
the glossary and the summary conventions. They name real people and belong only in
~/.local/share/life-recorder and the machine's own memory directory, never in a public repo.

summarize.sh wakes Claude only when a clip with new speech has been transcribed, and tells it
which section times the day already has, so a later run cannot write a second section for a
minute that is already covered.
