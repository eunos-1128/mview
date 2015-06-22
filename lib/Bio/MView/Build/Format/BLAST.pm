# Copyright (C) 1997-2015 Nigel P. Brown
# $Id: BLAST.pm,v 1.12 2015/06/14 17:09:04 npb Exp $

###########################################################################
#
# generic BLAST material
#
###########################################################################
package Bio::MView::Build::Format::BLAST;

use Bio::MView::Build::Search;
use NPB::Parse::Regexps;

use strict;
use vars qw(@ISA);

@ISA = qw(Bio::MView::Build::Search);

#the name of the underlying NPB::Parse::Stream parser
sub parser { 'BLAST' }

my $MISSING_QUERY_CHAR = 'X';  #interpolate this between query fragments

my %Known_Parameters =
    (
     #name        => [ format       default  ]

     #BLAST* display various HSP selections
     'hsp'        => [ '\S+',       'ranked' ],

     #BLAST* (version 1)
     'maxpval'    => [ $RX_Ureal,   undef    ],
     'minscore'   => [ '\d+',       undef    ],

     #BLAST* (version 2)
     'maxeval'    => [ $RX_Ureal,   undef    ],
     'minbits'    => [ '\d+',       undef    ],
     'cycle'      => [ [],          undef    ],

     #BLASTN (version 1, version 2); BLASTX (version 2)
     'strand'     => [ [],          undef    ],

     #BLASTX/TBLASTX (version 1)
    );

#tell the parent
sub known_parameters { \%Known_Parameters }

#our own constructor since this is the entry point for different subtypes
sub new {
    shift;  #discard type
    my $self = new Bio::MView::Build::Search(@_);
    my ($type, $p, $v, $file);

    #determine the real type from the underlying parser
    ($p, $v) = (lc $self->{'entry'}->{'format'}, $self->{'entry'}->{'version'});

    $type = "Bio::MView::Build::Format::BLAST$v";
    ($file = $type) =~ s/::/\//g;
    require "$file.pm";
    
    $type .= "::$p";
    bless $self, $type;

    $self->initialise_parameters;
    $self->initialise_child;

    $self;
}

#called by the constructor
sub initialise_child {
    my $self = shift;
    my $scheduler = $self->scheduler;
    #warn "initialise_child ($scheduler)\n";
    while (1) {
        $self->{scheduler} = new Bio::MView::Build::Scheduler,
        last if $scheduler eq 'none';

        $self->{scheduler} = new Bio::MView::Build::Scheduler([qw(+ -)]);
        last if $scheduler eq 'strand';

        if ($scheduler eq 'cycle') {
            my $last = $self->{'entry'}->count(qw(SEARCH));
            $self->{scheduler} = new Bio::MView::Build::Scheduler([1..$last]);
            last;
        }

        if ($scheduler eq 'cycle+strand') {
            my $last = $self->{'entry'}->count(qw(SEARCH));
            $self->{scheduler} =
                new Bio::MView::Build::Scheduler([1..$last], [qw(+ -)]);
            last;
        }

        die "initialise_child: unknown scheduler '$scheduler'";
    }
    return $self;
}

#called on each iteration
sub reset_child {
    my $self = shift;
    my $scheduler = $self->scheduler;
    #warn "reset_child ($scheduler)\n";
    while (1) {
        last if $scheduler eq 'none';

        #(warn "strands: [@{$self->{'strand'}}]\n"),
        $self->{scheduler}->filter($self->{'strand'}),
        last if $scheduler eq 'strand';

        #(warn "cycles: [@{$self->{'cycle'}}]\n"),
        $self->{scheduler}->filter($self->{'cycle'}),
        last if $scheduler eq 'cycle';

        #(warn "cycles+strands: [@{$self->{'cycle'}}][@{$self->{'strand'}}]\n"),
        $self->{scheduler}->filter($self->{'cycle'}, $self->{'strand'}),
        last if $scheduler eq 'cycle+strand';

        die "reset_child: unknown scheduler '$scheduler'";
    }
    return $self;
}

#current cycle being processed
sub cycle {
    my $scheduler = $_[0]->scheduler;
    return $_[0]->{scheduler}->item       if $scheduler eq 'cycle';
    return ($_[0]->{scheduler}->item)[0]  if $scheduler eq 'cycle+strand';
    return 1;
}

#current strand being processed
sub strand {
    my $scheduler = $_[0]->scheduler;
    return $_[0]->{scheduler}->item       if $scheduler eq 'strand';
    return ($_[0]->{scheduler}->item)[1]  if $scheduler eq 'cycle+strand';
    return '+';
}

sub subheader {
    my ($self, $quiet) = (@_, 0);
    my $s = '';
    return $s  if $quiet;
    if ($self->{'hsp'} eq 'all') {
	$s .= "HSP processing: all\n";
    } elsif ($self->{'hsp'} eq 'discrete') {
	$s .= "HSP processing: discrete\n";
    } else {
	$s .= "HSP processing: ranked\n";
    }
    $s;
}

#override base class method to process query row differently
sub build_rows {
    my $self = shift;
    my ($lo, $hi, $i);

    #first, compute alignment length from query sequence in row[0]
    ($lo, $hi) = $self->set_range($self->{'index2row'}->[0]);
    
    #warn "range ($lo, $hi)\n";
       
    #query row contains missing query sequence, rather than gaps
    $self->{'index2row'}->[0]->assemble($lo, $hi, $MISSING_QUERY_CHAR);

    #assemble sparse sequence strings for all rows
    for ($i=1; $i < @{$self->{'index2row'}}; $i++) {
	$self->{'index2row'}->[$i]->assemble($lo, $hi, $self->{'gap'});
    }
    $self;
}


###########################################################################
###########################################################################
package Bio::MView::Build::Row::BLAST;

use Bio::MView::Build::Row;

use strict;
use vars qw(@ISA);

@ISA = qw(Bio::MView::Build::Row);

sub posn1 {
    my $qfm = $_[0]->{'seq'}->fromlabel1;
    my $qto = $_[0]->{'seq'}->tolabel1;
    return "$qfm:$qto";
}

sub posn2 {
    my $hfm = $_[0]->{'seq'}->fromlabel2;
    my $hto = $_[0]->{'seq'}->tolabel2;
    return "$hfm:$hto"  if defined $_[0]->num and $_[0]->num;
    return '';
}

sub sort { $_[0]->sort_worst_to_best }

#don't sort fragments: take them in discovery/insert order
sub sort_none {$_[0]}

#sort fragments: (1) increasing score, (2) increasing length; used by
#Row::assemble(); as originally used up to MView version 1.58.1
sub sort_worst_to_best {
    $_[0]->{'frag'} = [
        sort {
            my $c = $a->[7] <=> $b->[7];                 #compare score
            return $c  if $c != 0;
            return length($a->[0]) <=> length($b->[0]);  #compare length
        } @{$_[0]->{'frag'}}
       ];
    $_[0];
}

#sort fragments: (1) decreasing score, (2) decreasing length; used by
#Row::assemble(); taking into account the NO OVERWRITE policy in Sequence.pm
sub sort_best_to_worst {
    $_[0]->{'frag'} = [
        sort {
            my $c = $b->[7] <=> $a->[7];                 #compare score
            return $c  if $c != 0;
            return length($b->[0]) <=> length($a->[0]);  #compare length
        } @{$_[0]->{'frag'}}
	];
    $_[0];
}

sub assemble {
    my $self = shift;
    $self->SUPER::assemble(@_);
}

###########################################################################
package Bio::MView::Build::Row::BLASTX;

use strict;
use vars qw(@ISA);

@ISA = qw(Bio::MView::Build::Row::BLAST);

#recompute range for translated sequence
sub range {
    my $self = shift;
    my ($lo, $hi) = $self->SUPER::range;
    $self->translate_range($lo, $hi);
}

#assemble translated
sub assemble {
    my $self = shift;
    foreach my $frag (@{$self->{'frag'}}) {
        ($frag->[1], $frag->[2]) =
            $self->translate_range($frag->[1], $frag->[2]);
    }
    $self->SUPER::assemble(@_);
}


###########################################################################
1;
