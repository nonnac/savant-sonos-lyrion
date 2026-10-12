package Plugins::SavantSonos::Plugin;

# Savant Sonos Bridge
# Plain-text HTTP endpoints on the Lyrion web port for the Savant profile:
#   /plugins/SavantSonos/status.txt?mac=<player mac>          -> SRC:TV|STATE:PLAYING|VOL:30|MUTE:0|PWR:1|
#   /plugins/SavantSonos/cmd.txt?mac=<player mac>&do=<cmd>[&val=<n>]
#       do = tv | lyrion | off | vol (val 0-100) | volup | voldown (val step) | mute (val 0/1) | refresh
#            join (val = master player mac, or room index from the matrix room list) | leave
#   /plugins/SavantSonos/cmd.txt?do=rooms&val=<mac1>,<mac2>,...   (matrix room list, index 1..n)
# Player mac -> Sonos RINCON comes from the UPnP Bridge config; Sonos IPs from SSDP discovery.
# When a polled Sonos switches to TV (or another app) the Lyrion player is powered off.

use strict;
use base qw(Slim::Plugin::Base);

use IO::Socket::INET;
use Socket qw(sockaddr_in inet_aton inet_ntoa);
use File::Spec::Functions qw(catfile);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Networking::Select;

my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.savantsonos',
	defaultLevel => 'WARN',
	description  => 'PLUGIN_SAVANTSONOS',
});

use constant POLL_SECS   => 2;
use constant ACTIVE_SECS => 120;   # keep polling a Sonos this long after Savant last asked about it
use constant SSDP_SECS   => 600;

my %dev;     # lc mac => { udn, ip, src, state, vol, mute, seen, busy }
my $ssdp;
my @rooms;   # matrix room list: index 1..n => player mac (index 0 unused)
my $MACRE = qr/^[0-9a-f]{2}(?::[0-9a-f]{2}){5}$/;

sub initPlugin {
	my $class = shift;
	$class->SUPER::initPlugin(@_);

	Slim::Web::Pages->addPageFunction(qr{^plugins/SavantSonos/status\.txt}, \&pageStatus);
	Slim::Web::Pages->addPageFunction(qr{^plugins/SavantSonos/cmd\.txt},    \&pageCmd);

	Slim::Utils::Timers::setTimer(undef, time() + 3, \&discover);
	Slim::Utils::Timers::setTimer(undef, time() + 5, \&pollAll);
	$log->warn('Savant Sonos Bridge started');
}

# ---------- mapping ----------

sub loadMap {
	my $dir = eval { Slim::Utils::Prefs::dir() } || eval { Slim::Utils::OSDetect::dirsFor('prefs') } || '/config/prefs';
	my $f = catfile($dir, 'upnpbridge.xml');
	open(my $fh, '<', $f) or do { $log->warn("Can't read $f"); return };
	local $/; my $x = <$fh>; close $fh;
	for my $d (split /<device>/, $x) {
		my ($u) = $d =~ m{<udn>uuid:([^<]+)</udn>};
		my ($m) = $d =~ m{<mac>([^<]+)</mac>};
		next unless $u && $m;
		$dev{lc $m}{udn} = $u;
	}
}

sub entry {
	my $mac = lc(shift || '');
	return unless $mac =~ $MACRE;
	loadMap() unless $dev{$mac} && $dev{$mac}{udn};
	return $dev{$mac} && $dev{$mac}{udn} ? $dev{$mac} : undef;
}

# ---------- SSDP discovery ----------

sub discover {
	Slim::Utils::Timers::killTimers(undef, \&discover);
	Slim::Utils::Timers::setTimer(undef, time() + SSDP_SECS, \&discover);
	loadMap();
	closeSSDP();
	$ssdp = IO::Socket::INET->new(Proto => 'udp', LocalPort => 0, Broadcast => 1, Blocking => 0) or do {
		$log->warn("SSDP socket failed: $!"); return;
	};
	my $msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: urn:schemas-upnp-org:device:ZonePlayer:1\r\n\r\n";
	my $dst = sockaddr_in(1900, inet_aton('239.255.255.250'));
	send($ssdp, $msg, 0, $dst) for 1 .. 2;
	Slim::Networking::Select::addRead($ssdp, \&readSSDP);
	Slim::Utils::Timers::setTimer(undef, time() + 5, \&closeSSDP);
}

sub readSSDP {
	my $sock = shift;
	my $buf;
	my $from = recv($sock, $buf, 4096, 0) or return;
	my (undef, $addr) = sockaddr_in($from);
	my $ip = inet_ntoa($addr);
	my ($rincon) = $buf =~ /USN:\s*uuid:(RINCON_[0-9A-Za-z]+)/i or return;
	for my $mac (keys %dev) {
		next unless $dev{$mac}{udn} && $dev{$mac}{udn} eq $rincon;
		if (($dev{$mac}{ip} || '') ne $ip) {
			$log->warn("Sonos $rincon ($mac) at $ip");
			$dev{$mac}{ip} = $ip;
		}
	}
}

sub closeSSDP {
	return unless $ssdp;
	Slim::Networking::Select::removeRead($ssdp);
	close $ssdp;
	undef $ssdp;
}

# ---------- SOAP ----------

my %SVC = (
	AV => ['/MediaRenderer/AVTransport/Control',      'urn:schemas-upnp-org:service:AVTransport:1'],
	RC => ['/MediaRenderer/RenderingControl/Control', 'urn:schemas-upnp-org:service:RenderingControl:1'],
);

sub soap {
	my ($d, $svc, $action, $args, $cb) = @_;
	return unless $d->{ip};
	my ($path, $urn) = @{ $SVC{$svc} };
	my $body = qq{<?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:$action xmlns:u="$urn"><InstanceID>0</InstanceID>$args</u:$action></s:Body></s:Envelope>};
	Slim::Networking::SimpleAsyncHTTP->new(
		sub { my $http = shift; $cb->($http->content) if $cb },
		sub { my ($http, $err) = @_; $log->warn("SOAP $action to $d->{ip} failed: $err"); $d->{ip} = undef if $err =~ /connect|timed out|refused/i; },
		{ timeout => 4 },
	)->post("http://$d->{ip}:1400$path",
		'Content-Type' => 'text/xml; charset="utf-8"',
		'SOAPACTION'   => qq{"$urn#$action"},
		$body);
}

sub xmlval {
	my ($c, $tag) = @_;
	my ($v) = ($c || '') =~ m{<$tag>([^<]*)</$tag>};
	return unless defined $v;
	$v =~ s/&lt;/</g; $v =~ s/&gt;/>/g; $v =~ s/&quot;/"/g; $v =~ s/&amp;/&/g;
	return $v;
}

# ---------- polling ----------

sub pollAll {
	Slim::Utils::Timers::killTimers(undef, \&pollAll);
	Slim::Utils::Timers::setTimer(undef, time() + POLL_SECS, \&pollAll);
	my $now = time();
	my $needDiscover = 0;
	for my $mac (keys %dev) {
		my $d = $dev{$mac};
		next unless $d->{seen} && $now - $d->{seen} < ACTIVE_SECS;
		if (!$d->{ip}) { $needDiscover = 1; next }
		pollOne($mac);
	}
	discover() if $needDiscover && !$ssdp;
}

sub pollOne {
	my $mac = shift;
	my $d = $dev{$mac};
	soap($d, 'AV', 'GetMediaInfo', '', sub { setSrc($mac, xmlval(shift, 'CurrentURI')) });
	soap($d, 'AV', 'GetTransportInfo', '', sub { my $s = xmlval(shift, 'CurrentTransportState'); $d->{state} = $s if defined $s });
	soap($d, 'RC', 'GetVolume', '<Channel>Master</Channel>', sub { my $v = xmlval(shift, 'CurrentVolume'); $d->{vol} = $v if defined $v });
	soap($d, 'RC', 'GetMute', '<Channel>Master</Channel>', sub { my $v = xmlval(shift, 'CurrentMute'); $d->{mute} = $v if defined $v });
}

sub classify {
	my $uri = shift;
	return 'IDLE'   if !defined $uri || $uri eq '';
	return 'TV'     if $uri =~ /^x-sonos-htastream:/;
	return 'LYRION' if $uri =~ m{/bridge-};
	return 'GROUP'  if $uri =~ /^x-rincon:/;
	return 'OTHER';
}

sub setSrc {
	my ($mac, $uri) = @_;
	my $d = $dev{$mac};
	my $src = classify($uri);
	my $prev = $d->{src};
	$d->{src} = $src;
	if (defined $prev && $prev ne $src && ($src eq 'TV' || $src eq 'OTHER' || $src eq 'GROUP')) {
		$log->warn("$mac switched $prev -> $src, turning Lyrion player off");
		lyrionOff($mac);
	}
}

sub lyrionOff {
	my $mac = shift;
	my $client = Slim::Player::Client::getClient($mac) or return;
	$client->execute(['power', 0]) if $client->power;
}

# ---------- web pages ----------

# Savant appends its interface postfix (a newline) to every URL, so the last
# query parameter arrives as e.g. "0\n". Trim all parameters.
sub param {
	my ($params, $name) = @_;
	my $v = $params->{$name};
	return '' unless defined $v;
	$v =~ s/^\s+|\s+$//g;
	return $v;
}

sub pageStatus {
	my ($client, $params) = @_;
	my $mac = lc(param($params, 'mac'));
	my $d = entry($mac);
	my $body;
	if (!$d) {
		$body = "SRC:UNKNOWN|STATE:UNKNOWN|VOL:0|MUTE:0|PWR:0|\n";
	} else {
		pollOne($mac) if $d->{ip} && (!$d->{seen} || time() - $d->{seen} >= ACTIVE_SECS);
		$d->{seen} = time();
		discover() if !$d->{ip} && !$ssdp;
		my $c = Slim::Player::Client::getClient($mac);
		$body = sprintf("SRC:%s|STATE:%s|VOL:%d|MUTE:%d|PWR:%d|\n",
			$d->{src} || 'UNKNOWN', $d->{state} || 'UNKNOWN', $d->{vol} || 0, $d->{mute} || 0, ($c && $c->power) ? 1 : 0);
	}
	return \$body;
}

sub pageCmd {
	my ($client, $params) = @_;
	my $mac = lc(param($params, 'mac'));
	my $do  = lc(param($params, 'do'));
	my $val = param($params, 'val');
	my $body = "OK\n";

	if ($do eq 'rooms') {
		# keep positions: blank or invalid slots stay empty so indexes match the matrix inputs
		my @list = map { lc(s/^\s+|\s+$//gr) } split /,/, $val, -1;
		@rooms = (undef, map { $_ =~ $MACRE ? $_ : undef } @list);
		entry($_) for grep { defined } @rooms;   # load udn mapping
		$body = "OK rooms " . scalar(grep { defined } @rooms) . "\n";
		return \$body;
	}

	my $d = entry($mac);

	if (!$d) {
		$body = "ERR unknown player\n";
	} elsif (!$d->{ip}) {
		discover() unless $ssdp;
		$body = "ERR sonos not found yet\n";
	} else {
		$d->{seen} = time();
		if ($do eq 'tv') {
			lyrionOff($mac);
			$d->{src} = 'TV';
			soap($d, 'AV', 'SetAVTransportURI',
				"<CurrentURI>x-sonos-htastream:$d->{udn}:spdif</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>",
				sub { soap($d, 'AV', 'Play', '<Speed>1</Speed>') });
		} elsif ($do eq 'lyrion') {
			my $c = Slim::Player::Client::getClient($mac);
			$c->execute(['power', 1]) if $c && !$c->power;
		} elsif ($do eq 'off') {
			lyrionOff($mac);
		} elsif ($do eq 'vol') {
			my $v = int($val || 0); $v = 0 if $v < 0; $v = 100 if $v > 100;
			$d->{vol} = $v;
			unmute($d);
			soap($d, 'RC', 'SetVolume', "<Channel>Master</Channel><DesiredVolume>$v</DesiredVolume>");
		} elsif ($do eq 'volup' || $do eq 'voldown') {
			my $step = int($val || 2) || 2;
			$step = -$step if $do eq 'voldown';
			unmute($d);
			soap($d, 'RC', 'SetRelativeVolume', "<Channel>Master</Channel><Adjustment>$step</Adjustment>",
				sub { my $v = xmlval(shift, 'NewVolume'); $d->{vol} = $v if defined $v });
		} elsif ($do eq 'mute') {
			my $m = ($val eq '1' || lc($val) eq 'on' || lc($val) eq 'true') ? 1 : 0;
			$d->{mute} = $m;
			soap($d, 'RC', 'SetMute', "<Channel>Master</Channel><DesiredMute>$m</DesiredMute>");
		} elsif ($do eq 'join') {
			my $mmac = $val =~ /^\d+$/ ? $rooms[$val] : lc $val;
			my $m = $mmac ? entry($mmac) : undef;
			if (!$m) {
				$body = "ERR unknown master '$val' (send the matrix room list first)\n";
			} elsif ($mmac eq $mac) {
				leaveGroup($d);
			} else {
				lyrionOff($mac);
				$d->{src} = 'GROUP';
				soap($d, 'AV', 'SetAVTransportURI',
					"<CurrentURI>x-rincon:$m->{udn}</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>");
			}
		} elsif ($do eq 'leave') {
			leaveGroup($d);
		} elsif ($do eq 'refresh') {
			pollOne($mac);
		} else {
			$body = "ERR unknown command\n";
		}
		main::INFOLOG && $log->is_info && $log->info("cmd $do " . ($val // '') . " for $mac: $body");
	}
	return \$body;
}

sub leaveGroup {
	my $d = shift;
	return unless ($d->{src} || '') eq 'GROUP';
	$d->{src} = 'IDLE';
	soap($d, 'AV', 'BecomeCoordinatorOfStandaloneGroup', '');
}

sub unmute {
	my $d = shift;
	return unless $d->{mute};
	$d->{mute} = 0;
	soap($d, 'RC', 'SetMute', '<Channel>Master</Channel><DesiredMute>0</DesiredMute>');
}

sub shutdownPlugin {
	Slim::Utils::Timers::killTimers(undef, \&pollAll);
	Slim::Utils::Timers::killTimers(undef, \&discover);
	closeSSDP();
}

1;
