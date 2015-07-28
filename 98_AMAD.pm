# $Id: 98_AMAD.pm 1001 2015-07-23 12:58:05Z leongaultier $
##############################################################################
#
#     98_AMAD.pm
#
#     Get and Set http Requests from/to AutomagicAPP Device
#     
##############################################################################

use strict;
use warnings;
use Time::HiRes qw(gettimeofday);
use HttpUtils;
use Blocking;

sub AMAD_Initialize($) {

    my ($hash) = @_;

    $hash->{SetFn}     	= "AMAD_Set";
    $hash->{DefFn}      = "AMAD_Define";
    $hash->{UndefFn}    = "AMAD_Undef";
    $hash->{AttrFn}     = "AMAD_Attr";
    $hash->{ReadFn}     = "AMAD_Read";
    $hash->{AttrList} =
          "interval disable:0,1 nonblocking:0,1 "
         . $readingFnAttributes;
}

##########################################################################

sub AMAD_RetrieveAutomagicInfo
{
    my ($name, $blocking) = @_;
    my $hash = $defs{$name};
  # my $name = $hash->{NAME};
    my $host = $hash->{HOST};
    my $port = $hash->{PORT};

    my $url = "http://" . $host . ":" . $port . "/automagic/test";
  
    if ($blocking) {
  	#my $response = GetFileFromURL($url, 5, undef, 0);
  	my $response = HttpUtils_BlockingGet(
			{
			  url        => $url,
			  timeout    => 5,
			  #noshutdown => 0,
			}
			);
	my %param = (hash => $hash, doTrigger => 0);
	AMAD_RetrieveAutomagicInfoFinished(\%param, undef, $response);
	Log3 $name, 3, "AMAD ($name) - BlockingGet get URL ";
    }
    else {
	HttpUtils_NonblockingGet(
	  {
	      url        => $url,
	      timeout    => 5,
	      #noshutdown => 0,
	      hash       => $hash,
	      doTrigger  => 1,
	      callback   => \&AMAD_RetrieveAutomagicInfoFinished,
	  }
	);
	Log3 $name, 3, "AMAD ($name) - NonblockingGet get URL";
    }
}

sub AMAD_RetrieveAutomagicInfoFinished($$$)
{
    my ( $param, $err, $data ) = @_;
    my $hash = $param->{hash};
    my $doTrigger = $param->{doTrigger};
    my $name = $hash->{NAME};
    my $host = $hash->{HOST};

    Log3 $name, 3, "AMAD ($name) - AMAD_RetrieveAutomagicInfoFinished: calling Host: $host";

    if (defined($err)) {
      if ($err ne "")
      {
	  Log3 $name, 3, "AMAD ($name) - AMAD_RetrieveAutomagicInfoFinished: error while requesting AutomagicInfo: $err";
	  return;
      }
    }

    if($data eq "" and exists($param->{code}))
    {
        Log3 $name, 3, "AMAD ($name) - AMAD_RetrieveAutomagicInfoFinished: received http code ".$param->{code}." without any data after requesting AMAD AutomagicInfo";
        return;
    }
    
    $hash->{RETRIEVECACHE} = $data;
    
    my @valuestring = split('@@',  $data);
    my %buffer;
    foreach (@valuestring) {
	my @values = split(' ', $_);
	$buffer{$values[0]} = $values[1];
    }

    readingsBeginUpdate($hash);
    my $t;
    my $v;
    while (($t, $v) = each %buffer) {
	readingsBulkUpdate($hash, $t, $v) if (defined($v));
    }
    readingsEndUpdate($hash, 1);
}

########################################################################################

sub AMAD_GetUpdateLocal($)
{
  my ($hash) = @_;
  my $name = $hash->{NAME};

  AMAD_RetrieveAutomagicInfo($name, 1);

  return 1;
}

############################################################################

sub AMAD_GetUpdateTimer($)
{
  my ($hash) = @_;
  my $name = $hash->{NAME};
 
  AMAD_RetrieveAutomagicInfo($name, 0);
  
  InternalTimer(gettimeofday()+$hash->{INTERVAL}, "AMAD_GetUpdateTimer", $hash, 1);
  Log3 $name, 3, "AMAD ($name) - Call AMAD_GetUpdateTimer";

  return 1;
}

##########################################################################

sub
AMAD_Set($@)
{
  my ($hash, @a) = @_;
  my $name = shift @a;

  return "no set value specified" if(int(@a) < 1);
  my $setList = AttrVal($name, "setList", " ");
  return "Unknown argument ?, choose one of $setList" if($a[0] eq "?");

  my @rl = split(" ", AttrVal($name, "readingList", ""));
  if(@rl && grep /\b$a[0]\b/, @rl) {
    my $v = shift @a;
    readingsSingleUpdate($hash, $v, join(" ",@a), 1);
    return;
  }

  my $v = join(" ", @a);
  Log3 $name, 4, "AMAD ($name) set $name $v";

  readingsSingleUpdate($hash,"state",$v,1);
  return undef;
}

###########################################################################

sub AMAD_Define($$) {

    my ( $hash, $def ) = @_;
    my @a = split( "[ \t][ \t]*", $def );

    return "too few parameters: define <name> AMAD <HOST> <PORT> <interval>" if ( @a != 5 );

    my $name    	= $a[0];
    my $host    	= $a[2];
    my $port		= $a[3];
    my $interval  	= 120;

    if(int(@a) == 5) {
        $interval = int($a[4]);
        if ($interval < 5 && $interval) {
           return "interval too small, please use something > 5 (sec), default is 120 (sec)";
        }
    }

    $hash->{HOST} 	= $host;
    $hash->{PORT} 	= $port;
    $hash->{INTERVAL} 	= $interval;

    Log3 $name, 3, "AMAD ($name) - defined with host $hash->{HOST} and interval $hash->{INTERVAL} (sec)";

    AMAD_GetUpdateLocal($hash);

    InternalTimer(gettimeofday()+$hash->{INTERVAL}, "AMAD_GetUpdateTimer", $hash, 0);
    
    $hash->{STATE} = "active";

    return undef;
}

sub AMAD_Undef($$) {
    my ($hash, $arg) = @_;

    RemoveInternalTimer($hash);

    return undef;
}

sub AMAD_Attr(@) {
        my ( $cmd, $name, $attrName, $attrVal) = @_;
        my $hash = $defs{$name};

        if ($attrName eq "disable") {
          if($cmd eq "set") {
              if($attrVal eq "0") {
                RemoveInternalTimer($hash);
                InternalTimer(gettimeofday()+2, "AMAD_GetUpdateTimer", $hash, 0) if ($hash->{STATE} eq "disabled");
                $hash->{STATE}='active';
                Log3 $name, 4, "AMAD ($name) - enabled";
             } else {
                $hash->{STATE} = 'disabled';
                RemoveInternalTimer($hash);
                Log3 $name, 4, "AMAD ($name) - disabled";
             }
          } elsif ($cmd eq "del") {
             RemoveInternalTimer($hash);
             InternalTimer(gettimeofday()+2, "AMAD_GetUpdateTimer", $hash, 0) if ($hash->{STATE} eq "disabled");
             $hash->{STATE}='active';
             Log3 $name, 4, "AMAD ($name) - enabled";
          }
        } else {
          if($cmd eq "set") {
             $attr{$name}{$attrName} = $attrVal;
             Log3 $name, 4, "AMAD ($name) - $attrName : $attrVal";
          } elsif ($cmd eq "del") {
          }
       }

        return undef;
}

################################################################################

1;