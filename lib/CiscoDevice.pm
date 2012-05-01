package CiscoDevice;
#
#	Cisco device control object.
#	Allows you to programically login and control a device via its CLI.
# 	This was originally created for cisco IOS devices. Net::Telnet::Cisco
#       would not work properly for me since I needed reverse telnet
#       functionality.
#	-- Jason
#
#	@author Jason Morriss <lifo101@gmail.com>
#
#	$Id$
#

use strict;
use warnings;
use Carp;
use IO::File;
use IO::Handle;
use FileHandle;
use IPC::Open2;
require Expect; import Expect;	# avoid errors in my Komodo IDE

BEGIN {
    use Module::Load::Conditional qw( can_load );
    # optional dependency
    our $XMODEM = can_load( modules => { 'XModem' => undef } );
}

our $VERSION = '1.0';
our $DEBUG = 0;

# Define defaults used for newly created objects
our %DEFAULTS = (
	# if true new() will attempt to connect automatically.
	# if false connect() must be called manually by the caller.
	autoconnect 	=> 1,
	# if true send() will make sure a newline "\n" is always sent with a
	# command; except if ^Z is being sent.
	autonewline	=> 1,
	# if true send() will strip off the command sent from the result before
	# returning it. On routers/switches the command sent is normally echoed
	# back to the client and enabling this will cause it to be stripped.
	autostripcmd	=> 1,
	# connection command: 'telnet' or 'ssh'; this is the actual command
	# that is spawned by expect. Use the 'options' paramater to pass in
	# extra options to the spawned command.
	command		=> 'telnet',
	# extra command connection options. Arrayref or string.
	options		=> undef,
	# timeout in seconds for any command (can be overridden in send())
	timeout		=> 20,
	# delay before sending wakeup("\n") after connecting. 0=disabled.
	wakeup		=> 0,
	# prompt REGEX
	prompt		=> qr/((?m:^[\r\b]?[\w.-]+\s?(?:\(config[^\)]*\))?\s?[\$\#>]\s?(?:\(enable\))?\s*$))/,
	#user_prompt	=> qr/[\r\n][a-zA-Z0-9\/-]+(?<!<(context|unknown))[>#]\s*/,
	#exec_prompt 	=> qr/[\r\n][a-zA-Z0-9\/-]+\(config[\-a-zA-Z]*\)#\s*/,
	exp_delay_prompt=> 0,
	# object level debug.
	debug		=> 0,
	# if true all input/output is printed to STDERR
	verbose		=> 0,
);

# new('host')
# new(host => 'host',
#	port => 'port',
#	username => 'username',
#	password => 'password',
#	command => 'telnet',
#	options => {})
sub new {
	my $proto = shift;
	my $class = ref($proto) || $proto;
	my $self = {};
	bless($self, $class);

	# must have 1 or an even number of arguments
	if (@_ == 0 || (@_ > 1 and @_ % 2 == 1)) {
		croak("Invalid usage in $class->new(): Odd number of paramaters");
	}

	my %args = (
		# make sure certain keys exist
		(map { $_ => undef } qw(
			debug
			host port username password enable
			command connected authenticated
		)),
		# merge defaults
		%DEFAULTS
	);
	# merge hashref(s) into a args hash
	while (@_ and ref $_[0] eq 'HASH') {
		%args = (%args, %{shift()});
	}
	# merge remaining named paramaters
	if (@_ > 1 and @_ % 2 == 0) {	# must be even
		%args = (%args, @_);
	} else {
		# single paramater available; assume host
		$args{host} = shift if @_;
	}

	# verify....
	if (!defined $args{host} or $args{host} eq '') {
		croak("Invalid usage in $class->new(): \"host\" not specified");
	}
	if (!defined $args{command} or $args{command} eq '') {
		croak("Invalid usage in $class->new(): \"command\" not specified");
	}
	if (exists $args{options} and ref $args{options}) {
		if (ref $args{options} ne 'ARRAY') {
			croak("Invalid usage in $class->new(): \"options\" must be a string or an ARRAY ref")
		}
	}
	
	# sanitize ...
	if (!defined $args{port}) {
		if ($args{command} eq 'telnet') {
			$args{port} = 23;
		} elsif ($args{command} eq 'ssh') {
			$args{port} = 22;
		} else {
			croak("Invalid usage in $class->new(): \"port\" not specified and unknown for \"$args{command}\"");
		}
	}

	#use Data::Dumper; warn Dumper(\%args);
	%$self = %args;
	if ($self->{autoconnect}) {
		return unless $self->connect;
		$self->wakeup($args{wakeup}) if $args{wakeup};
	}
	return $self;
}

# Connect to device
sub connect {
	my $self = shift;
	my $cmdstr = $self->build_connect_command();
	my $exp = $self->new_expect_object();
	$self->{connected} = 0;

	if (!$exp->spawn($cmdstr)) {
		$self->{error} = $! || $exp->before;
		return 0;
	} else {
		$self->{connected} = 1;
		#if ($self->{wakeup}) {
		#	my $wakeup;
		#	use Data::Dumper; warn Dumper(\%$self);
		#	$exp->expect($self->{timeout},
		#		#[ qr/Trying/ => sub { $exp->clear_accum; exp_continue() } ], 
		#		[ qr/Connection refused/ => sub { $self->exp_refused(@_) } ],
		#		[ qr/Escape character is/ => sub {
		#			$wakeup = 1;
		#			$self->exp_connected(@_);
		#		} ],
		#	);
		#	if ($wakeup) {
		#		$self->wakeup($self->{wakeup});
		#	}
		#}
	}
	$self->{exp} = $exp;
	return $self->{connected};
}

# disconnect from device. If $hard is true a hard close is done and returns
# immediately. Otherwise a soft close is done and may take up to 15 seconds to
# return.
sub disconnect {
	my ($self, $hard) = @_;
	if ($self->{exp}) {
		if ($hard) {
			$self->{exp}->hard_close;
		} else {
			$self->{exp}->soft_close;
		}
		undef $self->{exp};
	}
}

# return a command string that will be used to spawn the expect process.
sub build_connect_command {
	my ($self) = @_;
	my @cmd;
	push @cmd, $self->{command};
	if (defined $self->{options}) {
		if (ref $self->{options}) {
			push @cmd, @{$self->{options}};
		} else {
			push @cmd, $self->{options};
		}
	}
	# i dont like hard coding this right here, but eh... owell.
	if ($self->{command} eq 'ssh' and exists $self->{username} and defined $self->{username}) {
		# ssh user@host -p port
		push @cmd, $self->{username} . '@' . $self->{host};
		push @cmd, '-p ' . $self->{port} if exists $self->{port} and $self->{port} ne '22';
	} else {
		# telnet host port
		push @cmd, $self->{host};
		push @cmd, $self->{port} if exists $self->{port};
	}

	return join(' ', @cmd);
}

# expect() shortcut to wait for certain patterns w/o sending a command first.
# ->expect([patterns])
# ->expect(timeout => 10, patterns => [])
#sub do_expect {
#	my $self = shift;
#	my %opt;
#	$opt{patterns} = shift if @_ == 1;
#	croak "Odd number of elements in " . (caller 0)[3] . "(...)" if @_ and @_ % 2 == 1;
#	%opt = (%opt, @_);
#	
#	$opt{timeout} //= $self->{timeout};
#	$opt{prompt} //= $self->{prompt};
#	$opt{patterns} //= [];
#	
#	return $self->{exp}->expect($opt{timeout},
#		@{$opt{patterns}},
#		[ $opt{prompt} => sub { $self->exp_prompt(@_) } ],
#	);
#}

# ->send("command", timeout => 10, capture => 0, prompt => '', expect => 0)
sub send {
	my $self = shift;
	my $cmd = shift;
	croak "Odd number of elements in " . (caller 0)[3] . "(...)" if @_ and @_ % 2 == 1;
	my %opt = @_;

	# set defaults
	$opt{capture} //= 1;
	$opt{timeout} //= $self->{timeout};
	$opt{prompt} //= $self->{prompt};
	$opt{expect} //= 1;
	$opt{patterns} //= [];

	# alter $cmd as-needed
	if (exists $opt{end} and defined $opt{end}) {
		# append the ending terminator (could be "")
		$cmd .= $opt{end};
	} else {
		# make sure "\n" is appended to the end unless cmd is ^Z
		if ($self->{autonewline} and $cmd ne "\cZ") {
			$cmd .= "\n" if $cmd !~ /\n$/
		}
	}
	
	#my $cap = $self->capturing;
	$self->{result} = '';
	if ($self->{verbose}) {
		print STDERR "<<< $cmd";
		print STDERR "\n" unless $cmd =~ /\n$/;
	}
	$self->{lastcmd} = $cmd;
	$self->{exp}->send($cmd);
	#$self->stop_capture if $opt{capture} and $cap;
	
	my $ok = 1;
	$ok = $self->{exp}->expect($opt{timeout},
		@{$opt{patterns}},	# allow caller to add more/override patterns
		[ $opt{prompt} => sub { $self->exp_prompt(@_) } ],
		[ qr/^<--- More --->\s*$/m => sub { $self->exp_more(@_) } ],
		[ qr/^\s+--More--\s*$/m => sub { $self->exp_more(@_) } ],
	) if $opt{expect};

	$self->{result} =~ s/\s{7}\x08+//g;	# remove "       ^H^H^H^H^H^H^H^H" (from --More-- prompts)
	$self->{result} =~ s/\r\s{14}\r//g;	# remove "              " (from <--- More ---> prompts)
	$self->{result} =~ tr/\r\x08//d;	# strip \r and extra backspaces ^H
	$self->parse_error($self->{result});

	if ($self->{autostripcmd}) {
		# chop off the first line (to remove command that was sent)
		$self->{result} = (split(/\n/, $self->{result}, 2))[1] || '';
	}

	return $self->{result};
}

# sends multiple lines to the device. this is useful for sending configurations
# or access-lists. 
# $cmd should be a string or an arrayref of lines to send.
# 'maxlines' specifies how many lines to send before waiting for a prompt (default: 1).
# That helps from overunning the device buffer with large configs, etc but can
# slow down the overall call to send_lines().
# ->send_lines('string or arrayref', timeout => '', maxlines => 10, ...)
sub send_lines {
	my $self = shift;
	my @lines = ref $_[0] eq 'ARRAY' ? @{shift()} : split(/\n/, shift);
	croak "Odd number of elements in " . (caller 0)[3] . "(...)" if @_ and @_ % 2 == 1;
	my %opt = @_;

	# set defaults for sending the command
	#$opt{capture} //= 1;
	$opt{maxlines} //= 1;
	$opt{timeout} //= $self->{timeout};
	$opt{prompt} //= $self->{prompt};
	$opt{patterns} //= [];
	#$opt{end} //= '';

	my $cnt = 0;
	while (defined(my $cmd = shift @lines)) {
		#$cmd =~ s/^\s+//;					# only trim left side
		#next if $cmd =~ /^[\s!]+$/;				# ignore blank lines and bang "!"
		$cnt++;
		
		if (exists $opt{end} and defined $opt{end}) {
			# append the ending terminator (could be "")
			$cmd .= $opt{end};
		} else {
			# make sure "\n" is appended to the end unless cmd is ^Z
			if ($self->{autonewline} and $cmd ne "\cZ") {
				$cmd .= "\n" if $cmd !~ /\n$/
			}
		}

		$self->{exp}->send($cmd);
		if (!@lines or ($opt{maxlines} and $cnt >= $opt{maxlines})) {
			$self->{exp}->expect($opt{timeout},
				@{$opt{patterns}},	# allow caller to add more patterns
				[ $opt{prompt} => sub { $self->exp_prompt(@_) } ],
				[ qr/^\s+--More--\s*$/m => sub { $self->exp_more(@_) } ],
			);
			$cnt = 0;
		}
	}
	
	$self->{result} =~ s/\s{7}\x08+//g;	# remove "       ^H^H^H^H^H^H^H^H" (from --More-- prompts)
	$self->{result} =~ s/\r\s{14}\r//g;	# remove "              " (from <--- More ---> prompts)
	$self->{result} =~ tr/\r\x08//d;	# strip \r and extra backspaces ^H
	$self->parse_error($self->{result});

	#if ($self->{autostripcmd}) {
	#	# chop off the first line (to remove command that was sent)
	#	$self->{result} = (split(/\n/, $self->{result}, 2))[1] || '';
	#}

	return $self->{result};
}

# generic "configure replace ..." function.
sub configure_replace {
	my $self = shift;
	my %opt;
	$opt{cmd} = shift if @_ == 1;
	croak "Odd number of elements in " . (caller 0)[3] . "(...)" if @_ and @_ % 2 == 1;
	%opt = (%opt, @_) if @_;

	$opt{patterns} //= [];

	my $cmd = "configure replace " . delete $opt{cmd};
	my $res = $self->send($cmd, %opt, patterns => [
		@{$opt{patterns}},
		[ qr/Enter Y if you are sure you want to proceed\. \? \[no\]:/ => sub{ $_[0]->send("y\n"); exp_continue(); } ]
	]);
}

# generic "copy" function. 
sub copy {
	my $self = shift;
	my %opt;
	$opt{cmd} = shift if @_ == 1;
	croak "Odd number of elements in " . (caller 0)[3] . "(...)" if @_ and @_ % 2 == 1;
	%opt = (%opt, @_) if @_;

	$opt{validate} //= 0;			# Perform image validation checks
	$opt{overwrite} //= 1;			# overwrite existing file?
	$opt{checksum} //= 1;			# Use crc block checksumming?
	$opt{erase} //= 0;			# Erase flash: before copying?

	my $cmd = delete $opt{cmd};
	$cmd = "copy $cmd" unless $cmd =~ /^copy/;
	my $res = $self->send($cmd, %opt, patterns => [
		[ qr/Proceed\? \[confirm\]/ => sub{ $_[0]->send("y"); exp_continue() } ],
		[ qr/Source filename \[.*\]\?/ => sub{ $_[0]->send("\n"); exp_continue() } ],
		[ qr/Destination filename \[.*\]\?/ => sub{$_[0]->send("\n"); exp_continue() } ],
		[ qr/Max Retry Count/ => sub{ $_[0]->send($opt{retry}."\n"); exp_continue() } ],
		[ qr/Perform image validation checks/ => sub{ $_[0]->send($opt{validate} ? 'y' : 'n'); exp_continue() } ],
		[ qr/Do you want to over write\? \[confirm\]/ => sub {$_[0]->send($opt{overwrite} ? 'y' : 'n'); exp_continue() } ],
		[ qr/Use crc block checksumming\? \[confirm\]/ => sub {$_[0]->send($opt{checksum} ? 'y' : 'n'); exp_continue() } ],
		[ qr/Continue\? \[confirm\]/ => sub{ $_[0]->send("y"); exp_continue() } ],
		[ qr/Erase flash: before copying\? \[confirm\]/ => sub{ $_[0]->send($opt{erase} ? 'y' : 'n'); exp_continue() } ],
	]);

	return $res;
}

# Copy a file UPTO the device. Note: This routine has only been tested with
# XMODEM at this time... 
sub copyto {
	my $self = shift;
	my %opt;
	$opt{file} = shift if @_ == 1;
	croak "Odd number of elements in " . (caller 0)[3] . "(...)" if @_ and @_ % 2 == 1;
	%opt = (%opt, @_) if @_;

	# set defaults for sending the command
	$opt{destination} //= '';
	$opt{protocol} //= 'xmodem';		# xmodem, ymodem
	$opt{retry} //= 10;			# Max Retry Count [10]
	$opt{validate} //= 0;			# Perform image validation checks
	$opt{timeout} //= 300;
	$opt{overwrite} //= 1;			# overwrite existing file?
	$opt{checksum} //= 1;			# Use crc block checksumming?
	$opt{erase} //= 0;			# Erase flash: before copying?
	$opt{verbose} //= $self->{verbose};
	$opt{isfile} //= 1;

	# verify....
	if (!defined $opt{file} or $opt{file} eq '') {
		croak("Invalid usage in " . ref($self) . "->copyto(): \"file\" not specified");
	}
	if (!defined $opt{destination} or $opt{destination} eq '') {
		croak("Invalid usage in " . ref($self) . "->copyto(): \"destination\" not specified");
	}
	if ($opt{retry} ne '' and $opt{retry} !~ /^\d+$/) {
		croak("Invalid usage in " . ref($self) . "->copyto(): \"retry\" must be between 1 and 255");
	}

	my $res = $self->send("copy $opt{protocol}: $opt{destination}", %opt, patterns => [
		[ qr/Proceed\? \[confirm\]/ => sub{ $_[0]->send("y"); exp_continue() } ],
		[ qr/Source filename \[.*\]\?/ => sub{
			$_[0]->send((split(/\//, $opt{destination},2))[1] . "\n");
			exp_continue()
		} ],
		[ qr/Destination filename \[.*\]\?/ => sub{$_[0]->send("\n"); exp_continue() } ],
		[ qr/Max Retry Count/ => sub{ $_[0]->send($opt{retry}."\n"); exp_continue() } ],
		[ qr/Perform image validation checks/ => sub{ $_[0]->send($opt{validate} ? 'y' : 'n'); exp_continue() } ],
		[ qr/Do you want to over write\? \[confirm\]/ => sub {$_[0]->send($opt{overwrite} ? 'y' : 'n'); exp_continue() } ],
		[ qr/Use crc block checksumming\? \[confirm\]/ => sub {$_[0]->send($opt{checksum} ? 'y' : 'n'); exp_continue() } ],
		[ qr/Continue\? \[confirm\]/ => sub{ $_[0]->send("y"); exp_continue() } ],
		[ qr/Erase flash: before copying\? \[confirm\]/ => sub{ $_[0]->send($opt{erase} ? 'y' : 'n'); exp_continue() } ],
		[ qr/(Ready to receive file|Begin the Ymodem transfer now|Begin the Xmodem or Xmodem-1K transfer now)\.+/ => sub {
			my $xm = new XModem($_[0], $_[0], verbose => $opt{verbose});
			if (!$xm->sendfile($opt{file}, pad => "\xff")) {
				$self->error("Error sending file: $@");
			}
			exp_continue();
		} ],
	]);

	return $res;
}

#sub copyfrom {
#	my $self = shift;
#	my %opt;
#	$opt{source} = shift if @_ == 1;
#	croak "Odd number of elements in " . (caller 0)[3] . "(...)" if @_ and @_ % 2 == 1;
#	%opt = (%opt, @_) if @_;
#
#	# set defaults for sending the command
#	$opt{destination} //= '';
#	$opt{protocol} //= 'xmodem';		# xmodem, ymodem
#	$opt{retry} //= 10;			# Max Retry Count [10]
#	$opt{validate} //= 0;			# Perform image validation checks
#	$opt{timeout} //= 300;
#	$opt{overwrite} //= 1;			# overwrite existing file?
#	$opt{checksum} //= 0;			# Use crc block checksumming?
#	$opt{verbose} //= $self->{verbose};
#
#	# verify....
#	if (!defined $opt{file} or $opt{file} eq '') {
#		croak("Invalid usage in " . ref($self) . "->copyto(): \"file\" not specified");
#	}
#	if (!defined $opt{source} or $opt{source} eq '') {
#		croak("Invalid usage in " . ref($self) . "->copyto(): \"source\" not specified");
#	}
#	if ($opt{retry} ne '' and $opt{retry} !~ /^\d+$/) {
#		croak("Invalid usage in " . ref($self) . "->copyto(): \"retry\" must be between 1 and 255");
#	}
#
#	my $res = $self->send("copy $opt{source} $opt{protocol}:", %opt, patterns => [
#		[ qr/Proceed\? \[confirm\]/ => sub{ $_[0]->send("y"); exp_continue() } ],
#		[ qr/Destination filename \[.+\]\?/ => sub{$_[0]->send("\n"); exp_continue() } ],
#		[ qr/Service Module \S+ number\?/ => sub{$_[0]->send("\n"); exp_continue() } ],
#		[ qr/1k buffer\? \[confirm\]/ => sub{$_[0]->send("\n"); exp_continue() } ],
#		[ qr/Max Retry Count/ => sub{ $_[0]->send($opt{retry}."\n"); exp_continue() } ],
#		[ qr/Continue\? \[confirm\]/ => sub{ $_[0]->send("y"); exp_continue() } ],
#		[ qr/(Ready to receive file|Begin the Xmodem or Xmodem-1K transfer now)\.+/ => sub {
#			my $xm = new XModem($_[0], $_[0], verbose => $opt{verbose});
#			if (!$xm->sendfile($opt{file})) {
#				$self->error("Error sending file: $@");
#			}
#			exp_continue();
#		} ],
#	]);
#
#	return $res;
#}


# Login with a password and optionally enable...
# ->login('password')
# ->login(password => 'password', enable => 'enable', prompt => '...', ...)
sub login {
	my $self = shift;
	my %opt;
	$opt{password} = shift if @_ == 1;
	croak "Odd number of elements in " . (caller 0)[3] . "(...)" if @_ and @_ % 2 == 1;
	%opt = (%opt, @_) if @_;

	# set defaults for sending the command
	$opt{timeout} //= $self->{timeout};
	$opt{prompt} //= $self->{prompt};
	$opt{password} //= $self->{password};
	#$opt{enable} //= $self->{enable};
	#$opt{patterns} //= [];

	$self->{_loggedin} = 0;
	$self->{_enabled} = 0;
	$self->{exp}->expect($opt{timeout},
		#@{$opt{patterns}},	# allow caller to add more patterns
		[ timeout => sub { $self->exp_nologin(@_, $! || "Timeout") } ],
		[ eof => sub { $self->exp_nologin(@_, $! || "EOF Found") } ],
		[ qr/Host key verification failed\./ => sub{ $self->exp_refused(@_) } ],
		[ qr/Connection refused/ => sub{ $self->exp_refused(@_) } ],
		#[ qr/[Uu]sername:/ => sub { undef } ], 
		[ qr/[Pp]assword:/ => sub {
			if ($self->{_loggedin}) {
				$self->exp_enable(@_, $opt{enable} || $opt{password});
			} else {
				 $self->exp_password(@_, $opt{password});
			}
		} ],
		[ qr/\(yes\/no\)\?/ => sub { $self->exp_accept_key(@_) } ],
		[ qr/Permission denied/ => sub { $self->exp_denied(@_) } ],
		[ qr/^%/m => sub { $self->exp_denied(@_) } ], 
		[ $opt{prompt} => sub { $self->exp_loggedin(@_) } ],
	);

	if ($self->{_loggedin} and $opt{enable}) {
		return $self->enable($opt{enable});
	}
	return $self->{_loggedin};
}

# attempt to enable.
# ->enable('password', prompt => '', timeout => '')
sub enable {
	my $self = shift;
	my %opt;
	$opt{password} = shift if @_ == 1;
	croak "Odd number of elements in " . (caller 0)[3] . "(...)" if @_ and @_ % 2 == 1;
	%opt = (%opt, @_) if @_;

	# set defaults for sending the command
	$opt{timeout} //= $self->{timeout};
	$opt{prompt} //= $self->{prompt};
	$opt{password} //= $self->{enable};
	#$opt{patterns} //= [];

	$self->{_enabled} = 0;
	$self->{exp}->send("enable\n");
	$self->{exp}->expect($opt{timeout},
		#@{$opt{patterns}},	# allow caller to add more patterns
		[ $opt{prompt} => sub {
			$self->exp_prompt(@_);
			# enabled is true if a hash is present on the prompt
			$self->{_enabled} = ($_[0]->match =~ /#\s*$/);
			undef;
		} ],
		[ qr/[Pp]assword:/ => sub { $self->exp_enable(@_, $opt{password}) } ],
		[ qr/Invalid/ => sub { $self->exp_noenable(@_) } ],
		[ qr/^%/m => sub { $self->exp_noenable(@_) } ], 
	);
	return $self->{_enabled};
}

# parses the string for possible errors.
sub parse_error {
	my ($self, $str) = @_;
	my @lines = split(/\n/, $str);
	# remove the first line since its the last command sent
	shift @lines;
	return unless @lines;	# no lines? then no error...

	$self->{error} = '';		# the error string
	$self->{error_col} = undef;	# the error column marker (if available)

	# if a caret is present on the first line then its an error marker
	if ($lines[0] =~ /^(\s*)\^/) {
		$self->{error_col} = length($1) - length($self->{exp}->match);
		$self->{error_col} = 0 if $self->{error_col} < 0;
		shift @lines;
	}

	$str = join "\n", @lines;
	# there's an error if a hash is present (but watch out for 'show cpu' results)
	if (($str =~ /%/ and $str =~ /ERROR/i) || defined $self->{error_col}) {
		$self->{error} = join("\n", @lines);
	} elsif (defined $self->{error_col}) {
		# if an error column marker was detected but no error string was
		# found then we'll report an unknown error. This shouldn't
		# really happen, but could I guess.
		$self->{error} = "Unknown error";
	}

	return $self->{error};
}

# helper function to process a directory (from flash, nvram, ...) and returns
# an array of hashref's for each filename found (includes name, size, perm, date)
# note: this has only been tested on a very small subset of lower end cisco
# devices and WILL NOT work properly on other models.
sub dir {
	my ($self, $path) = @_;
	$path //= '';
	my $out = $self->send("dir $path");
	return if $self->error;

	my @list;
	$out =~ s/\n\n/\n/gm;	# remove blank lines
	foreach my $line (split(/\n/, $out)) {
		$line =~ s/^\s+//;
		$line =~ s/\s+$//;
		next if $line =~ /^Directory of/i;				# first line
		next if $line =~ /(\d+) bytes total.+(\d+) bytes free/i;	# last line
		next if $line =~ /no files/i;

		if ($line =~ /^(\d+)\s+([-drwx]+)\s+(\d+)\s+(.+)/) {
			# 11  -rw-         991  Aug 29 2011 17:03:52 +00:00  filename
			my ($inode, $perm, $size) = ($1, $2, $3);
			my @tmp = split(/\s+/, $4);
			my $d = {
				inode	=> $inode,
				perm	=> $perm,
				dir	=> $perm =~ /d/ ? 1 : 0,	# true if node is a directory
				size	=> int($size),
				file	=> pop(@tmp),
				date	=> join(' ', @tmp)
			};
			push(@list, $d);
		} else {
			# failsafe; add the line as-is (string)
			push(@list, $line);
		}

	}
	return wantarray ? @list : \@list;
}

# create "make" a directory.
sub mkdir {
	my ($self, $path) = @_;
	$self->send("mkdir $path\n\n");
	return $self->error ? 0 : 1;
}

sub file_exists {
	my $self = shift;
	my $file = shift;
	my @dir = $self->dir($file);
	return @dir ? 1 : 0;
}

# remove a file/directory.
# Will fail on directories if not empty unless 'recursive' is specified.
# ->rm('path')
# ->rm(path => '', recursive => 1)
sub rm {
	my $self = shift;
	my %opt;
	$opt{path} = shift if @_ == 1;
	croak "Odd number of elements in " . (caller 0)[3] . "(...)" if @_ and @_ % 2 == 1;
	%opt = (%opt, @_) if @_;

	$opt{force} //= 1;	# so we don't get a prompt for each file
	$opt{recursive} //= 0;	# delete entire directory trees

	my $err;
	my $cmd = "delete";
	$cmd .= " /force" if $opt{force};
	$cmd .= " /recursive" if $opt{recursive};
	$cmd .= " " . $opt{path};
	$self->send($cmd, patterns => [
		[ qr/Delete filename/m => sub{ $_[0]->send("\n"); exp_continue() } ],
		[ qr/Delete .+ \[confirm\]/ => sub{ $_[0]->send("y"); exp_continue() } ],
		[ qr/Delete of .+ aborted!/ => sub{ exp_continue() } ],
		[ qr/No such file/ => sub{ $err = "No such file"; exp_continue() } ],
	]);
	$self->error($err) if $err and !$self->error;
	
	# "No such file" is not technically an error...
	return 1 if $err;
	return $self->error ? 0 : 1;
}


# ->reload(reason)
# ->reload(reason => '', wait => 0, warm => '', file => '', at => '', in => '', cancel => 1)
sub reload {
	my $self = shift;
	my %opt;
	$opt{reason} = shift if @_ == 1;
	croak "Odd number of elements in " . (caller 0)[3] . "(...)" if @_ and @_ % 2 == 1;
	%opt = (%opt, @_) if @_;

	$opt{reason} //= '';
	$opt{wait} //= 0;		# should we wait for reload to finish? assuming we're on console...
	$opt{timeout} //= 60*10;	# a reload can take a long time
	$opt{save} //= 1;		# "System configuration has been modified. Save?" -- respond with yes/no?
					# if -1 the reload will be aborted

	my $cmd = "reload";
	if ($opt{cancel}) {
		$cmd .= " cancel";
	} else {
		$cmd .= " warm" if $opt{warm};
		$cmd .= " file $opt{file}" if $opt{warm} and $opt{file};
		$cmd .= " at $opt{at}" if $opt{at};	# reload at hh:mm [[mon], day]
		$cmd .= " in $opt{in}" if $opt{in};
		$cmd .= " " . $opt{reason} if defined $opt{reason} and $opt{reason} ne '';
	}
	
	my $saved = 1;
	my $out = $self->send($cmd, timeout => $opt{timeout}, patterns => [
		[ qr/Save\? \[yes\/no\]:\s*/ => sub{
			$_[0]->send(($opt{save}?'y':'n') . "\n");
			$saved = $opt{save};
			exp_continue()
		} ],
		[ qr/^Proceed with reload\? \[confirm\]/m => sub{
			$_[0]->send($saved ? 'y' : 'n');
			if (!$saved) {
				$self->error("Configuration not saved");
				return exp_continue();
			}
			return $opt{wait} ? exp_continue() : undef;
		} ],
		#[ qr/[\000\007]/ => sub{ exp_continue() } ],	# ignore null and bell
		#[ qr/^Press RETURN to get started/m => sub{ $self->{result} .= $_[0]->before; $_[0]->send("\n"); undef } ],
		[ qr/^Press RETURN to get started.\s*/m => sub{ $_[0]->clear_accum(); undef } ],
	]);
	$out =~ tr/\cG//d;	# remove "bell"
	return $out;
}

# Send a quick "wakeup" command. Useful for certain systems that do not provide
# prompt when initially connecting (like reverse telnet on cisco devices).
# $cmd is the command to send ("\n" by default).
# $delay is an optional delay in seconds before sending the command, this can be
# useful so you don't send the wakeup too early during the connection process.
# any other extra parameters are passed to send().
sub wakeup {
	my $self = shift;
	my %opt;
	$opt{delay} = shift if @_ == 1;
	croak "Odd number of elements in " . (caller 0)[3] . "(...)" if @_ and @_ % 2 == 1;
	%opt = (%opt, @_) if @_;

	$opt{cmd} //= "\r";
	$opt{end} //= "";
	$opt{delay} //= 0;
	$opt{retry} //= 0;
	$opt{retry_delay} //= 1;
	
	my $try = 0;
	my $done = $opt{retry} ? 0 : 1;
	my $cmd = delete $opt{cmd};
	my $awake = 0;
	my $res;
	
	select(undef, undef, undef, $opt{delay}) if $opt{delay};

	do {
		$try++;
		$res = $self->send($cmd, %opt, patterns => [
			[ $self->{prompt} => sub{ $done = 1; $awake = 1; undef } ]
		]);
		if (!$done and $opt{retry_delay}) {
			select(undef, undef, undef, $opt{retry_delay})
		}
		$done = 1 if !$opt{retry} or $try >= $opt{retry};
	} while (!$done);
	return $awake;
}

sub last_cmd { $_[0]->{lastcmd} }

# returns the last command sent including the prompt prefix, so "sh ver" might
# be returned as "router#sh ver"
sub last_prompt_cmd {
	my ($self) = @_;
	my @list = grep { defined } $self->{exp}->matchlist;
	my $str = join('',  @list ? @list : '') . ($self->{lastcmd} || '');
	$str .= "\n" if $str and $str !~ /\n$/;
	return $str;
}

sub exp_refused {
	my ($self, $exp) = @_;
	$self->{connected} = 0;
	$self->{error} = $exp->match;
	$exp->clear_accum;
	return;	# undef; stop
}

sub exp_connected {
	my ($self, $exp) = @_;
	$self->{connected} = 1;
	#$exp->clear_accum;
	return;	# undef; stop
}

sub exp_prompt {
	my ($self, $exp) = @_;
	$self->{before} = $exp->before;
	$self->{result} .= $exp->before;
	$exp->clear_accum;
	return $self->expect_continue;
}

sub exp_loggedin {
	my ($self, $exp) = @_;
	$self->{_loggedin} = 1;
	return;
}

sub exp_more {
	my ($self, $exp) = @_;
 	$self->{result} .= $exp->before;
	$exp->send(" ");	# send space, no newline
	return exp_continue();	# must return exp_continue() here
}

# permission denied while trying to login or enable
sub exp_denied {
	my ($self, $exp, $err) = @_;
	$err ||= "Permission Denied";
	$self->{error} = $err;
	# return undef to stop Expect after this match is found
	return;
}

sub exp_password {
	my ($self, $exp, $password) = @_;
	$password ||= $self->{password};
	$exp->send("$password\n");
	exp_continue();
}

sub exp_enable {
	my ($self, $exp, $enable) = @_;
	$enable ||= $self->{enable} || $self->{password};
	$exp->send("$enable\n");
	return exp_continue();
}

# an error occured trying to enable (bad password)
sub exp_noenable {
	my ($self, $exp, $err) = @_;
	$err ||= "Bad enable password";
	$self->{error} = $err;
	# return undef to stop Expect after this match is found
	return;
}

# an error occured or the connection timed out during login
sub exp_nologin {
	my ($self, $exp, $err) = @_;
	my $before = (ref $exp) =~ /Expect/ ? $exp->before : undef;
	$err ||= "Unknown Error";
	$self->{error} = $err . ($before ? "\nRemote error: $before\n" : "");
	# return undef to stop Expect after this match is found
	return;
}

sub exp_accept_key {
	my ($self, $exp) = @_;
	$exp->send("yes\n");
	return exp_continue();
}

# if delay_prompt is true then Expect will delay on each command sent.
# if delay_prompt is false then Expect will return instantly on each command.
sub expect_continue {
	$_[0]->{exp_delay_prompt} ? exp_continue() : undef;
}

# set/get last error message.
sub error {
	my $self = shift;
	return (@_ ? ($self->{error} = shift) : $self->{error}) || '';
}
sub error_column { $_[0]->{error_col} }

# get/set capturing flag.
sub capture {
	my $self = shift;
	return @_ ? ($self->{_capturing} = shift) : $self->{_capturing};
}

# capture output from spawned process.
sub _capture_out {
	my $self = shift;
	if ($self->{verbose}) {
		#print map { ">>> $_\n" } map { split /\r?\n/ } @_;
		local $| = 1;	# disable buffering
		print STDERR @_;
	}
	if ($self->capture) {
		$self->{captured} .= $_[0];
	}
}

sub new_expect_object {
	my $self = shift;
	my $exp = new Expect();
	# I don't need this, and it doesn't work when trying to call a script
	# from a non-tty process (like from PHP). So I'm commenting it out.
	#$exp->slave->clone_winsize_from(\*STDIN);

	# enable raw mode; doesn't really help us with firewalls and routers
	# since you can't disable echo on them unlike a linux shell.
	#$exp->raw_pty(1);

	# stop echoing everything to the console from the spawned process.
	# the ->capture method will echo to STDOUT as needed.
	$exp->log_stdout(0);

	# capture everything with our own method
	$exp->log_file(sub { $self->_capture_out(@_) });

	# reduce the size of the accumulator buffer otherwise Expect will
	# go VERY slowly when trying to fetch the ACL output.
	#$exp->match_max(1024 * 10);

	#$exp->restart_timeout_upon_receive(1);

	if ($self->debug) {
		#$exp->debug(1);
		$exp->exp_internal(1);
		# TODO: open debug.txt file for capture() method to print to.
	}

	return $exp;
}

# Class->debug(...) -> get/set debug level for global class.
# $obj->debug(...)  -> get/set debug level for $obj instance only.
sub debug {
	my $self = shift;
	if (ref $self) {	# instance
		return (@_ ? ($self->{debug} = shift) : (defined $self->{debug} ? $self->{debug} : $DEBUG)) || 0;
	} else {		# class
		return (@_ ? ($DEBUG = shift) : $DEBUG) || 0;
	}
}

# output a debug message.
sub bug {
	my $self = shift;
	my $msg = shift;
	my $level = shift || 1;
	return unless $self->debug >= $level;
	croak "Odd number of elements in " . (caller 0)[3] . "(...)" if @_ and @_ % 2 == 1;
	my %opt = @_;
	if (exists $opt{end} and defined $opt{end}) {
		# append the ending terminator (could be "")
		$msg .= $opt{end};
	} else {
		# by default always make sure "\n" is appened to the end
		$msg .= "\n" unless $msg =~ /\n$/;
	}
	my $file = exists $opt{file} ? $opt{file} : *STDERR;
	print $file $msg;
}

# set/get a class level default. Can be called as a package or object method.
sub default {
	my ($self, $var, $value) = @_;
	return unless exists $DEFAULTS{$var};
	if (@_ == 2) {
		return $DEFAULTS{$var};
	} elsif (@_ == 3) {
		return $DEFAULTS{$var} = $value;
	}
}

# return the current defaults hash
sub defaults { %DEFAULTS }

# intercept get/set subroutines
our $AUTOLOAD;
sub AUTOLOAD {
	return if $AUTOLOAD =~ /::DESTROY$/;
	my ($self) = @_;
	my ($var) = ($AUTOLOAD =~ /::(.+)$/);
	croak "Invalid autoloaded method \"$AUTOLOAD\" called" if !ref $self;

	# %VALID is an extra hash of valid variable names to allow for set/get
	# that are not in %DEFAULTS
	my %VALID = (map {$_, 1} qw( host port connected authenticated ));
	if (exists $DEFAULTS{$var} or exists $VALID{$var}) {
		no strict 'refs';
		# create setter/getter sub for this $var
		*$AUTOLOAD = sub { @_ == 1 ? $_[0]->{$var} : ($_[0]->{$var} = $_[1]) };
		goto &$AUTOLOAD;
	}
	
	croak "Can't locate object method \"$var\" via package \"" . __PACKAGE__ . "\" (from autoload)";
}

1;
