#!/bin/sh
# Applies the Savant compatibility patches to a Lyrion Music Server image at build time.
# Every patch checks that its anchor was found exactly once; if Lyrion changes the code,
# the build fails instead of producing a half-patched image.
set -eu

LMS=${LMS_DIR:-/lms}
PLUGIN_SRC=${PLUGIN_SRC:-/tmp/SavantSonos}

fail() { echo "PATCH FAILED: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1+2) Slim/Web/Cometd.pm
#   - Savant sends request subscriptions on /meta/subscribe with a "data" block and no
#     "subscription" field (old SqueezeCenter style). Lyrion 9 crashes on them
#     (Cometd/Manager.pm add_channels). Re-route them to /slim/subscribe.
#   - Savant puts its own Cometd clientId where the player MAC belongs. Swap in the MAC
#     from /config/savant-player.txt (one player MAC on the first line).
# ---------------------------------------------------------------------------
F=$LMS/Slim/Web/Cometd.pm
[ -f "$F" ] || fail "$F not found"
if ! grep -q "Savant compat" "$F"; then
  perl -0pi -e 's{(\n(\t+)if \( \!\$manager->is_valid_clid\( \$clid \) \) \{)}{\n$2# Savant compat: Savant sends request subscriptions on /meta/subscribe without a\n$2# "subscription" field (old SqueezeCenter style). Treat them as /slim/subscribe.\n$2if ( \$obj->{channel} eq q{/meta/subscribe} \&\& \!defined \$obj->{subscription}\n$2\t\&\& ref \$obj->{data} eq q{HASH} \&\& \$obj->{data}->{request} ) {\n$2\t\$obj->{channel} = q{/slim/subscribe};\n$2}\n$2# Savant compat 2: Savant uses its clientId as the player id. Swap in the real MAC.\n$2if ( ref \$obj->{data} eq q{HASH} \&\& ref \$obj->{data}->{request} eq q{ARRAY}\n$2\t\&\& defined \$obj->{data}->{request}->[0] \&\& \$obj->{data}->{request}->[0] =~ m{^[0-9a-f]{8}\$}\n$2\t\&\& open( my \$sfh, q{<}, q{/config/savant-player.txt} ) ) {\n$2\tmy \$smac = <\$sfh>; close \$sfh;\n$2\tif ( defined \$smac \&\& \$smac =~ m{([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5})} ) { \$obj->{data}->{request}->[0] = lc \$1; }\n$2}$1}' "$F"
fi
[ "$(grep -c 'Savant compat' "$F")" = "2" ] || fail "Cometd.pm anchor not found (Lyrion version changed?)"
echo "patched $F"

# ---------------------------------------------------------------------------
# 3) Slim/Menu/BrowseLibrary.pm
#   Some menu weights (e.g. "Composers" from Extended Browse Modes) come from prefs as
#   strings. Savant sorts the menu by weight and crashes (NSString vs NSNumber).
# ---------------------------------------------------------------------------
F=$LMS/Slim/Menu/BrowseLibrary.pm
[ -f "$F" ] || fail "$F not found"
if ! grep -q "Savant compat" "$F"; then
  perl -pi -e "s{^(\t*)weight => \\\$node->\{'weight'\},\s*\$}{\$1weight => (\\\$node->{'weight'} || 0) + 0, # Savant compat: numeric weight\n}" "$F"
fi
[ "$(grep -c 'Savant compat' "$F")" = "1" ] || fail "BrowseLibrary.pm anchor not found (Lyrion version changed?)"
echo "patched $F"

# ---------------------------------------------------------------------------
# 4) Savant Sonos Bridge plugin, installed as a built-in plugin
# ---------------------------------------------------------------------------
[ -f "$PLUGIN_SRC/Plugin.pm" ] || fail "plugin source not found at $PLUGIN_SRC"
D=$LMS/Slim/Plugin/SavantSonos
mkdir -p "$D"
cp "$PLUGIN_SRC/install.xml" "$PLUGIN_SRC/strings.txt" "$D/"
sed 's/Plugins::SavantSonos::/Slim::Plugin::SavantSonos::/g' "$PLUGIN_SRC/Plugin.pm" > "$D/Plugin.pm"
sed -i 's#<module>Plugins::SavantSonos::Plugin</module>#<module>Slim::Plugin::SavantSonos::Plugin</module>#' "$D/install.xml"
grep -q 'package Slim::Plugin::SavantSonos::Plugin' "$D/Plugin.pm" || fail "plugin namespace rewrite failed"
grep -q 'Slim::Plugin::SavantSonos::Plugin' "$D/install.xml" || fail "plugin install.xml rewrite failed"
chmod -R a+rX "$D"
echo "installed plugin to $D"
