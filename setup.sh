#!/data/data/com.termux/files/usr/bin/bash

set -e

echo "Updating Termux packages..."
pkg update -y
pkg upgrade -y

echo "Installing Python and curl..."
pkg install -y python curl

echo "Installing/updating BeautifulSoup4..."
python -m pip install --upgrade beautifulsoup4

echo
echo "Setup complete."