package Search;

use Exporter qw(import);
our @ISA = qw(Exporter);
our @EXPORT = qw(findOligo); #functions exported by default
our @EXPORT_OK = qw(blast); #functions for explicit export

use strict; use warnings; use diagnostics; use feature qw(say);
use Carp;

use Bio::Seq; use Bio::SeqIO;
use Bio::Tools::Run::StandAloneBlastPlus;
use MyConfig; use MyIO;

use Data::Dumper;

# ==============================================================================
#
#   CAPITAN:        Andres Breton, http://andresbreton.com
#   FILE:           Search.pm
#   LICENSE:
#   USAGE:
#   DEPENDENCIES:   - NCBI's BLAST+ CL utility
#
# ==============================================================================

=head1 NAME

Search - package searching CRISPR sequences and offsite targets

=head1 SYNOPSIS

Creation:
    use Search;

=head1 DESCRIPTION


=head1 EXPORTS

=head2 Default Behaviors

Exports findOligo subroutine by default

use Search;

=head2 Optional Behaviors

Search::blast;

=head1 FUNCTIONS

=cut

#-------------------------------------------------------------------------------
# MAIN

#- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
=head2 findOligo

    Arg [1]     : Sequences info hash to be searched

    Arg [2]     : Window size of CRISPR target

    Example     : findOligo($seqInfo, $windowSize)

    Description : Find CRISPR targets

    Returntype  : Hash of hashes reference

    Status      : Development

=cut
sub findOligo {
    my $filledUsage = 'Usage: ' . (caller(0))[3] . '($seqInfo, $windowSize)';
    @_ == 2 or confess wrongNumberArguments(), $filledUsage;

    my ($seqInfo, $windowSize) = @_;
    my (%CRISPRS, @CRPseqs);
    my $instance = 0; # track CRISPR count

    # Anonymous subroutine to find CRISPR sequences in forward and reverse strands.
    # Stores both strand findings in same hash (%CRISPRS) containing all information
    # and array (@CRPseqs) containing all CRISPR sequences [cause why not].
    my $go = sub {
            my ($sequence, $strand) = @_;

            say "Searching CRISPR sequences on $strand strand";

            my $seqLen = length($sequence);
            my ($gRNA, $PAM, $content, $contentG, $contentC, $GC);

            for (my $i = 0; $i < $seqLen; $i++) {
                my $window = substr $sequence, $i, $windowSize;

                # LAST STEP: When DONE LOOKING UP -- Return CRISPR sequences and information
                if ( length($window) < $windowSize ) { #don't go out of bounds when at end of sequence
                    foreach my $name (keys %CRISPRS) {
                        my $crispr = $CRISPRS{$name}{'gRNA'} . $CRISPRS{$name}{'PAM'}; #join gRNA + PAM sequence
                        $CRISPRS{$name}{'sequence'} = $crispr; # add CRISPR sequence (gRNA + PAM) to each hash
                        push @CRPseqs, $crispr # push each N-oligomer CRISPR seq to array
                    }
                    # Return references of HoH containing all CRISPR instances found and respective information for each + array with the all CRISPR sequences joined (kmer gRNA + PAM)
                    return(\%CRISPRS, \@CRPseqs);
                };

                if ($window =~ /(.+)(.GG)$/) {
                    ($gRNA, $PAM) = ($1, $2); # get first 'kmer' number of nucleotides in gRNA (kmer) + PAM (NGG), gRNA + PAM = crispr sequence
                    my $name = "CRISPR_$instance"; $instance++;

                    # GC Content
                    $contentG   = $window =~ tr/G//;
                    $contentC   = $window =~ tr/C//;
                    $GC         = ($contentG + $contentC)/$windowSize;

                    # Store CRISPR oligomers and info in Hash of Hashes
                    $content = { #anonymous hash of relevant gRNA content
                        'strand'    => $strand,
                        'start'     => $i,
                        'gRNA'      => $gRNA,
                        'PAM'       => $PAM,
                        'G'         => $contentG,
                        'C'         => $contentC,
                        'GC'        => $GC,
                    };
                    # Hash key == CRISPR sequence name
                    # Hash value == Hash with CRISPR content info
                    $CRISPRS{$name} = $content;
                }
            }
    };

    # Get all CRISPR sequences in forward and reverse strands of sequence passed, -seq
    $go->( $seqInfo->{'sequence'}, 'plus' );
    $go->( $seqInfo->{'reverse'}, 'reverse' );
}
#- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
=head2 blast

    Arg [1]     : CRISPR hash reference returned in findOligo sub

    Arg [2]     : Arrays with sequence file(s) provided for search

    Arg [3]     : Output file name

    Arg [4]     : Output directory

    Example     : blast(\%CRISPRS, $SEQ, $WINDOWSIZE)

    Description : Run BLAST+ search for CRISPR targets

    Returntype  : Hash reference

    Status      : Development

=cut
sub blast {
    my $filledUsage = 'Usage: ' . (caller(0))[3] . '(\%CRISPRfile, \@SUBJSEQS, $OUTFILE, $OUTDIR)';
    @_ == 4 or confess wrongNumberArguments(), $filledUsage;

    my ($CRPfile, $SUBJSEQS, $OUTFILE, $OUTDIR) = @_;
    my @SUBJSEQS = @$SUBJSEQS;
    my (%targets, $info);

    my $wordSize = 7;
    mkDir("$OUTDIR/blast");

    foreach my $subject (@SUBJSEQS) {
        my $subjName = _getSeqName($subject);
        my $outFile = "$OUTDIR/blast/$subjName\_$OUTFILE\.blast";

        say "Searching CRISPR targets against $subject";

        # Create StandAloneBlastPlus Factory
        my $fac = Bio::Tools::Run::StandAloneBlastPlus->new(
                    -db_data    => $subject,
                );

        # Perform BLAST call
        $fac->blastn(   -query          => $CRPfile,
                        -outfile        => $outFile,
                        -method_args    => [ -word_size => 7],
                    );

        # Rewind to beginning of results and get all
        $fac->rewind_results;
        # Process each CRISPR
        while ( my $result = $fac->next_result ) {
            my ($crispr) = $result->query_name =~ /(.*):\d+/;; # CRISPR sequence name ex.) 'CRISPR_0', removes appendend positioning
# say $crispr;
            # Process each CRISPR hit
            while ( my $hit = $result->next_hit ) {
# my $subjectName = $hit->name;
                # Process each match (HSP) in iterative fashion
                while( my $hsp = $hit->next_hsp ) {
                    # Get all values and store in hashes
                    my $qstart  = $hsp->start('query');
                    my $qend    = $hsp->end('query');
                    my $sseqid  = $hit->name;
                    my $sstart  = $hsp->start('hit');
                    my $send    = $hsp->end('hit');
                    my $sstrand = $hsp->strand('hit');
                    my $pident  = $hsp->percent_identity;
                    my $nident  = $hsp->num_identical;
                    my $gaps    = $hsp->gaps;

                    $info = { #anonymous hash with BLAST info for each match

                        'qstart'    => $qstart,
                        'qend'      => $qend,
                        'sseqid'    => $sseqid,
                        'sstart'    => $sstart,
                        'send'      => $send,
                        'sstrand'   => $sstrand,
                        'pident'    => $pident,
                        'nident'    => $nident,
                    };
                        # Hash of Hashes of Hashes of Arrays of Hash to store BLAST results for each query
                        # -- Hash key == CRISRP name
                        # -- Hash key == Subject name
                        # -- Hash key == 'info'
                        # -- Array accounts for multiple hits for each CRISPR sequence as hashes....
                        # -- Hash contains BLAST match info
                            push @{ $targets{$crispr}{$subjName}{'info'} } , $info;
                    }
                }
            }
            $fac->cleanup;
        }
    say "\tBLAST files saved in: '$OUTDIR/blast' ";
    return(\%targets);
}

#-------------------------------------------------------------------------------
# HELPERS

sub _getSeqName {
    my ($seq) = @_;

    # Sequence OO
    my $seqInObj    = Bio::SeqIO->new(-file => $seq, -alphabet => "dna");
    my $format      = $seqInObj->_guess_format($seq); #check format of input file
    my $seqObj      = $seqInObj->next_seq;
    my $name        = $seqObj->display_id;

    return $name;
}

# sub _blastCheck {
#     my ($) = @_;
# }

=head1 COPYRIGHT AND LICENSE

Andres Breton © 2016

[LICENSE]

=head1 CONTACT

Please email comments or questions to Andres Breton, <dev@andresbreton.com>

=head1 SETTING PATH

If PERL5LIB was not set, do something like this:

use FindBin; use lib "$FindBin::RealBin/lib";

This finds and uses subdirectory 'lib' in current directoy as library location

=cut
1;
