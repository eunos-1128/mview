# Copyright (C) 1996-2018 Nigel P. Brown

###########################################################################
package NPB::Parse::Substring;

use vars qw(@ISA);
use FileHandle;
use NPB::Parse::Message;
use strict;

@ISA = qw(NPB::Parse::Message);

$NPB::Parse::Substring::Debug = 0;

sub new {
    my $type = shift;
    #warn "${type}::new()\n"  if $NPB::Parse::Substring::Debug;
    NPB::Parse::Message::die($type, "new() invalid argument list (@_)")
	if @_ < 1;
    return new NPB::Parse::Substring::String(@_) if ref $_[0];#arg = string ref
    new NPB::Parse::Substring::File(@_);   #arg = filename
}

#sub DESTROY { warn "DESTROY $_[0]\n" }

sub get_file    { '' }
sub get_length  { $_[0]->{'extent'} }
sub get_base    { $_[0]->{'base'} }
sub startofline { $_[0]->{'lastoffset'} }
sub bytesread   { $_[0]->{'thisoffset'} - $_[0]->{'lastoffset'} }
sub tell        { $_[0]->{'thisoffset'} }

###########################################################################
package NPB::Parse::Substring::File;

use vars qw(@ISA);
use POSIX;
use FileHandle;
use strict;

@ISA = qw(NPB::Parse::Substring);

$NPB::Parse::Substring::File::open  = 1;
$NPB::Parse::Substring::File::close = 2;
$NPB::Parse::Substring::File::error = 4;

sub new {
    my $type = shift;
    #warn "${type}::new()\n"  if $NPB::Parse::Substring::Debug;
    my ($file, $base) = (@_, 0);
    my $self = {};
    bless $self, $type;

    $self->{'file'}   = $file;
    $self->{'base'}   = $base;
    $self->{'state'}  = $NPB::Parse::Substring::File::close;
    $self->{'lastoffset'} = undef;
    $self->{'thisoffset'} = undef;
    $self->{'fh'} = -1;

    $self->_open;

    #find file extent
    #$self->{'fh'}->seek(0, SEEK_END);
    $self->{'extent'} = (stat $self->{'fh'})[7];

    $self;
}

sub get_file {$_[0]->{'file'}}

sub close {
    #warn "close()\n"  if $NPB::Parse::Substring::Debug;
    $_[0]->_close;
}

sub open {
    #warn "open()\n"  if $NPB::Parse::Substring::Debug;
    $_[0]->reopen(@_);
}

sub reopen {
    my $self = shift;
    #warn "reopen()\n"  if $NPB::Parse::Substring::Debug;
    if ($self->{'state'} & $NPB::Parse::Substring::File::error or $self->{'state'} & $NPB::Parse::Substring::File::open) {
	$self->_close;
    }
    $self->_open;
    $self->_reset;
    $self;	
}

sub reset {
    my $self = shift;
    #warn "reset(@_)\n"  if $NPB::Parse::Substring::Debug;
    if ($self->{'state'} & $NPB::Parse::Substring::File::error) {
	$self->_close;
	$self->_open;
    } elsif ($self->{'state'} & $NPB::Parse::Substring::File::close) {
	$self->_open;
    }
    $self->_reset(@_);
    $self;	
}

sub _seek {
    my ($self, $new) = @_;
    my $old = $self->{'thisoffset'};
    #warn "seek: entry: $old, $new\n"  if $NPB::Parse::Substring::Debug;
    if ($old != $new) {
        unless (seek($self->{'fh'}, $new-$old, SEEK_CUR)) {
            warn "seek: failed\n";
            return 0;
        }
    }
    return 1;
}

sub _reset {
    my $self = shift;
    my ($offset) = (@_, $self->{'base'});
    #warn "_reset(@_)\n"  if $NPB::Parse::Substring::Debug;
    $self->{'fh'}->seek($offset, SEEK_SET);
    $self->{'lastoffset'} = $offset;
    $self->{'thisoffset'} = $offset;
    $self;
}

sub _close {
    my $self = shift;
    warn "_close()\n"  if $NPB::Parse::Substring::Debug;
    return $self  if $self->{'state'} & $NPB::Parse::Substring::File::close;
    $self->{'fh'}->close;
    $self->{'fh'} = -1;
    $self->{'state'} = $NPB::Parse::Substring::File::close;
    $self;
}

sub _open {
    my $self = shift;
    #warn "_open()\n"  if $NPB::Parse::Substring::Debug;
    $self->{'fh'} = new FileHandle  if $self->{'fh'} < 1;
    $self->{'fh'}->open($self->{'file'}) or $self->die("_open() can't open ($self->{'file'})");
    $self->{'state'} = $NPB::Parse::Substring::File::open;
    $self->{'lastoffset'} = $self->{'base'};
    $self->{'thisoffset'} = $self->{'base'};
    $self;
}

sub substr {
    my $self = shift;
    #warn "substr(@_)\n"  if $NPB::Parse::Substring::Debug;
    if ($self->{'state'} & $NPB::Parse::Substring::File::close) {
	$self->die("substr() can't read on closed file '$self->{'file'}'");
    }
    my ($offset, $bytes) = (@_, $self->{'base'}, $self->{'extent'}-$self->{'base'});
    my $buff = '';

    $self->{'lastoffset'} = $offset;
    if ($self->_seek($offset)) {
        my $c = read($self->{'fh'}, $buff, $bytes);
        $self->{'thisoffset'} = $offset + $c;
    }

    $buff;
}

sub getline {
    my $self = shift;
    #warn "getline(@_)\n"  if $NPB::Parse::Substring::Debug;
    my ($offset) = (@_, $self->{'thisoffset'});

    $self->{'lastoffset'} = $offset;

    return undef  unless $self->_seek($offset);

    my $fh = $self->{'fh'};
    my $line = <$fh>;

    return undef  unless defined $line;

    $self->{'thisoffset'} = $offset + length($line);
    #warn "getline:  $self->{'lastoffset'}, $self->{'thisoffset'}\n";

    #consume CR in CRLF if file came from DOS/Windows
    $line =~ s/\015\012/\012/go;
    $line;
}

###########################################################################
# A wrapper for a string held in memory to mimic a Substring::File

package NPB::Parse::Substring::String;

use vars qw(@ISA);
use NPB::Parse::Message;
use strict;

@ISA = qw(NPB::Parse::Substring);

sub new {
    my $type = shift;
    #warn "${type}::new()\n"  if $NPB::Parse::Substring::Debug;
    my $self = {};
    ($self->{'text'}, $self->{'base'}) = (@_, 0);
    $self->{'extent'} = length ${$self->{'text'}};
    $self->{'lastoffset'} = undef;
    $self->{'thisoffset'} = undef;
    bless $self, $type;
}

sub close  {$_[0]}
sub open   {$_[0]}
sub reopen {$_[0]}

sub reset {
    my $self = shift;
    my ($offset) = (@_, $self->{'base'});
    #warn "reset(@_)\n"  if $NPB::Parse::Substring::Debug;
    $self->{'lastoffset'} = $offset;
    $self->{'thisoffset'} = $offset;
    $self;
}

sub substr {
    my $self = shift;
    my ($offset, $bytes) = (@_, $self->{'base'}, 
			    $self->{'extent'}-$self->{'base'});
    CORE::substr(${$self->{'text'}}, $offset, $bytes);
}

sub getline {
    my $self = shift;
    my ($offset) = (@_, $self->{'base'});

    $self->{'lastoffset'} = $offset;

    my $i = index(${$self->{'text'}}, "\n", $offset);
    my $line;
    if ($i > -1) {
        $line = CORE::substr(${$self->{'text'}}, $offset, $i-$offset+1);
    } else {
        $line = CORE::substr(${$self->{'text'}}, $offset);
    }

    $self->{'thisoffset'} = $offset + length($line);

    return undef  unless defined $line;

    #consume CR in CRLF if file came from DOS/Windows
    $line =~ s/\015\012/\012/go;
    $line;
}

###########################################################################
1;
