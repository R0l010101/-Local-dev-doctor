#!/bin/sh
# Installs ERP Doctor: the `doctor` PowerShell command + the git post-checkout hook.
PROFILE_DIR="/c/Users/User/Documents/WindowsPowerShell"
PROFILE_FILE="$PROFILE_DIR/Microsoft.PowerShell_profile.ps1"
LINE="function doctor { & 'C:\Users\User\tools\erp-doctor\doctor.ps1' @args }"

mkdir -p "$PROFILE_DIR"
if grep -qF "erp-doctor" "$PROFILE_FILE" 2>/dev/null; then
    echo "doctor command: already installed"
else
    echo "$LINE" >> "$PROFILE_FILE"
    echo "doctor command: installed"
fi

cp /c/Users/User/tools/erp-doctor/post-checkout /c/xampp1/htdocs/erp/.git/hooks/post-checkout
echo "git hook: installed"
echo "Done. Open a NEW PowerShell window and type: doctor"
