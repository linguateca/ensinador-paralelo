package EnsinadorParalelo;
use Dancer2;

use CWB::CQP::More::Parallel 0.06;
use Try::Tiny;
use utf8;

our $VERSION = '0.1';

$ENV{CORPUS_REGISTRY} = config->{corpus_registry}
  if exists config->{corpus_registry};

our $utf8c =
  exists(config->{corpora_encoding}) && (config->{corpora_encoding} !~ /^utf.*8$/) ? 0 : 1;

get '/' => sub {
    template 'index' => {
                         corpora      => config->{corpora},
                         json_corpora => to_json(config->{corpora}, { utf8 => $utf8c }),
                        };
};

post '/concs/save' => sub {
  my $ids = param("b");
  my $concs = session 'concs';
  my @concs = @{$concs}[@$ids];

  template 'show' => { concs => \@concs };
};

post '/concs' => sub {
	# left, right, corpus, #direction

    my $concs = get_concordancies(param("left"),
                                  param("right"),
                                  param("language"),
                                  param("corpus"),
                                 );
    session concs => $concs;

    template 'concs' => {
                         concs => $concs,
                         query => {
                          left  => param("left"),
                          right => param("right"),
                         },
                        };
};

sub get_concordancies {
    my ($left, $right, $dir, $corpus) = @_;

    my $corpus_info = config->{corpora}{$corpus};
    redirect "/" unless defined $corpus_info;
    redirect "/" unless defined $left;


    my $cqp = CWB::CQP::More::Parallel->new( { utf8 => $utf8c } );

    my $name = $corpus_info->{cqpNames}[$dir];

    $cqp->change_corpus($corpus_info->{cqpNames}[$dir]);
    my $other = $corpus_info->{cqpNames}[!$dir];

    $cqp->set(c  => [1, config->{corpora}{$corpus}{context} ],
              LD => "'<b>'",
              RD => "'</b>'");

    my @lines;
    try {
        my $r = $right ? ":$other $right" : "";
        $cqp->exec("A = $left $r;");
        @lines = $cqp->cat('A');
    } catch {
        die $_;
    };

    my $f = sub {
      $_[0] =~ s/^.*?://;
      $_[0] =~ s/<p[^>]+>/<br\/>/g;
      $_[0] =~ s/<.?mwe[^>]*>//g;

      if ($_[0] =~ m/<b>/) {
        $_[0] = [ split m{</?b>}, $_[0] ];
      } 

      $_[0]
    };
    my $id = 0;
    return [map {
        $_->[0] = $f->($_->[0]);
        $_->[1] = $f->($_->[1]);
        +{ left => $_->[0], right => $_->[1], id => $id++ }
    } @lines];
}

true;
