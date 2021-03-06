use strict;
use warnings;
use feature 'state';

use Media::EmberMM;
use XML::LibXML;
use Dune::DuneImage;
use Dune::DuneFolder;
use Encode qw( encode );
use Win32::API;
use Win32::Unicode::Native;
use Time::HiRes qw(gettimeofday tv_interval);
use Config::IniFiles;
my $cfg = Config::IniFiles->new( -file => "IndexDune.ini" );

our $modtime = {};

my  $t0 = [gettimeofday];

our $process_all = 1;
our $template_dir = $cfg->val('template', 'directory')."\\";

my $dboutname = $cfg->val('database', 'name');
my $hostname = $cfg->val('database', 'host');
my $port = $cfg->val('database', 'port');
my $user = $cfg->val('database', 'user');
my $pwd = $cfg->val('database', 'password');
my $dsn = "DBI:mysql:database=$dboutname;host=$hostname;port=$port";
my $dir = $cfg->val('output', 'directory');

my $emm = Media::EmberMM->new($dsn, $user, $pwd);

$process_all = $cfg->val('mode', 'process_all');
my $template = $cfg->val('template', 'files');
process_template($template, $emm, $dir) if $cfg->val('mode', 'process_files');

$process_all = 1;
$template = $cfg->val('template', 'menus');
process_template($template, $emm, $dir) if $cfg->val('mode', 'process_menus');

my $elapsed = tv_interval ( $t0);
print "Finished $elapsed\n";

sub process_template {
	my $template = shift;
	my $emm = shift;
	my $dir = shift;
	my $row = {};
	my $parser = XML::LibXML->new();
	my $doc    = $parser->parse_file($template);
	my $image;
	my $pargs = {};

	process_node($dir, $pargs, $emm, $doc->firstChild, $image, $row);
}

sub process_node {
	my $dir = shift;
	my $pargs = shift;
	my $emm = shift;
	my $node = shift;
	my $image = shift; 
	my $row = shift;
	
	my @nodes = $node->getChildrenByTagName('*');
	foreach my $child (@nodes) {
		my $type = $child->getAttribute('type');
#		print $child->nodeName.' '.$type."\n";
		if($type eq 'table') {
			process_table($dir, $pargs, $child, $image);
		} elsif($type eq 'image') {
			process_file_image($dir, $pargs, $emm, $child, $row)
		} elsif($type eq 'folder') {
			process_folder($dir, $pargs, $emm, $child, $row)
		} elsif($type eq 'index') {
			process_index($dir, $pargs, $emm, $child, $row)
		} else {
			process_element($dir, $pargs, $emm, $child, $row, $image);
		}
	}
}

sub process_table {
	my $dir = shift;
	my $pargs = shift;
	my $node = shift;
	my $image = shift;
	
	my $table = $node->getAttribute('table');
	my $rows = $node->hasAttribute('rows') ? $node->getAttribute('rows') : 99999;
	my $skip = $node->hasAttribute('skip') ? $node->getAttribute('skip') : 0;
	
	$dir = process_dir($dir, $node);

	my $subdir = $node->hasAttribute('subdir') ? $node->getAttribute('subdir') : '';
	my $orderby = $node->hasAttribute('orderby') ? $node->getAttribute('orderby') : '';

#	print "Table: ".$table."\n";

	my $row = {};
	my $args = getargs ($dir, $pargs, $template_dir, $node, $row);

	my $newdir = $dir;
	$emm->clearquery($table);
	my $i=0;
	
	if($skip > 0) {
		while ((my $row = $emm->next($table, $orderby)) && $skip--) {}		
	}
	
	while ((my $row = $emm->next($table, $orderby)) && $rows--) {
		if($subdir ne '') {
			my $sd = $node->hasAttribute('format') ? sprintf($node->getAttribute('format'), $row->{$subdir}) : $row->{$subdir};
			$newdir = $dir."\\".$sd;
			mkdir $newdir;
		}
		$row->{'rownum'} = $i;
		$i++;

		process_node($newdir, $args, $emm, $node, $image, $row);
	}
}

sub check_node {
	my $node = shift;
	my $dir = shift;
	my $row = shift;
	my $filename = shift;
		
	my $rc = 1;
	if($node->parentNode->nodeName eq 'movie' || $node->parentNode->nodeName eq 'episode' || (($node->parentNode->nodeName eq 'tvshow') && !($filename =~ /dune_folder.txt/)))
	{
#		print "Checking: ".$node->nodeName.' '.$filename."\n";
		my $dmtime = 0;
		my $emtime = 0;
		if($filename =~ /dune_folder.txt/) {
			$dmtime = get_mod_time($dir.'\\dune_folder.txt');
			$emtime = check_stat($row, 'NfoPath');
		} else
		{
			$dmtime = get_mod_time($dir.'\\icon.aai');
			$emtime = check_stat($row, 'NfoPath');
			my $pmtime = check_stat($row, 'PosterPath');
			$emtime = $emtime > $pmtime ? $emtime : $pmtime;
			if(exists($row->{'FanartPath'}) && defined($row->{'FanartPath'}) && $row->{'FanartPath'} ne '') {
				my $famtime = check_stat($row, 'FanartPath');
				$emtime = $emtime > $famtime ? $emtime : $famtime;
			}
		}
#		print "$filename: $dmtime, $emtime\n";
		$rc = $process_all if($dmtime > $emtime);
	}
	elsif($node->parentNode->nodeName eq 'season')
	{
#		print "Checking: ".$node->nodeName.' '.$filename."\n";
		my $imtime = get_mod_time($dir.'\\icon.aai');
		my $fmtime = get_mod_time($dir.'\\dune_folder.txt');

		$rc = $process_all if($imtime > 0 && $fmtime > 0);
	}	
#	print "Skipped: ".$node->parentNode->nodeName.' '.$filename."\n" if !$rc;
	
	return $rc;
}

sub check_stat
{
	my $row = shift;
	my $type = shift;

	my $rc = 0;
	if(exists($row->{$type}) && $row->{$type}) {
		$rc = get_mod_time($row->{$type});
	}
	return $rc;
}

sub get_mod_time {
	my $file = shift;

	my $mtime = 0;
	if(exists($modtime->{$file})) {
		$mtime = $modtime->{$file};
	}
	else {
		$mtime = (stat($file))[9];
		$mtime = 0 if !defined($mtime);
		$modtime->{$file} = $mtime;
	}

	return $mtime;
}

sub process_file_image {
	my $dir = shift;
	my $pargs = shift;
	my $emm = shift;
	my $node = shift;
	my $row = shift;

	my $name = decode_attr($node, 'name', $node->nodeName, $row);
	my $filename = $dir.'\\'.$name.'.aai';
	if($process_all || check_node($node, $dir, $row, $filename))
	{
		my $args = getargs ($dir, $pargs, $template_dir, $node, $row);
		my $image = Dune::DuneImage->new($template_dir, $args->{'width'}, $args->{'height'});	
		process_node($dir, $args, $emm, $node, $image, $row);
		print "writing $filename\n";
		$image->write($filename);
	}
}

sub process_folder {
	my $dir = shift;
	my $pargs = shift;
	my $emm = shift;
	my $node = shift;
	my $row = shift;
#	print "Folder: ".$dir."\n";

	my $filename = $dir.'\\dune_folder.txt';
	if($process_all || check_node($node, $dir, $row, $filename))
	{
		my $folder = Dune::DuneFolder->new();	
		process_node($dir, $pargs, $emm, $node, $folder, $row);
		print "writing $filename\n";
		$folder->write($filename);
	}
}
	
sub process_index {
	my $dir = shift;
	my $pargs = shift;
	my $emm = shift;
	my $node = shift;
	my $row = shift;
#	print "Index: ".$node->nodeName."\n";

	$dir = process_dir($dir, $node);

	my $args = getargs ($dir, $pargs, $template_dir, $node, $row);
	process_node($dir, $args, $emm, $node, "", $row);
}
	
sub process_element {
	my $dir = shift;
	my $pargs = shift;
	my $emm = shift;
	my $node = shift;
	my $row = shift;
	my $obj = shift;
#	print "Element: ".$node->nodeName."\n";	
	
	my $args = getargs ($dir, $pargs, $template_dir, $node, $row);
	
	my $expr = '$obj->'.$node->nodeName.'($args)';
#	print $expr."\n"; 
	eval($expr);
}

sub process_dir {
	my $dir = shift;
	my $node = shift;

	if($node->hasAttribute('dir')) {
		$dir .= "\\".$node->getAttribute('dir');
#		print "Directory: $dir\n";
	    mkdir $dir;
	}
	return $dir;
}
sub decode_attr {

	my $node = shift;
	my $attr = shift;
	my $name = shift;
	my $row = shift;
	
	if($node->hasAttribute($attr)) {
		$name = $node->getAttribute($attr);
		if(exists($row->{$name})) {
			$name = $row->{$name};
			if($node->hasAttribute('format')) {
				$name = sprintf($node->getAttribute('format'), $name);
			}
		}
	}
	return $name;
}
	
sub getargs {
	my $dir = shift;
	my $pargs = shift;
    my $template_dir = shift;
    my $node = shift;
    my $row = shift;

    my $args = get_default_args($pargs, $row);
    
	foreach my $n ($node->findnodes("@*")) {
		$args->{$n->nodeName} = $n->nodeValue;
#		print "***$n\n";
	}

	if(exists($args->{'type'})) {
		my $type = $args->{'type'};
		my $target = (	$node->nodeName eq 'text' || 
						$node->nodeName eq 'menutext' || 
						$node->nodeName eq 'media' || 
						$node->nodeName eq 'area' || 
						$node->nodeName eq 'item' || 
						$node->nodeName eq 'index' || 
						$node->nodeName eq 'backgroundimage'
						) ? 'text' : 'filename';
						
		if(($node->nodeName eq 'text') && exists($args->{'table'})) {
			$args->{'text'} = gettextfromtable($emm, $node, $type);
		} 	
		elsif($type eq 'static') {
			$args->{$target} = $node->textContent;
		} 	
		elsif($type eq 'output') {
			$args->{$target} = $dir.'\\'.$node->textContent;
		} 	
		elsif(exists($args->{'media'})) {
			$args->{'filename'} = $row->{$args->{'media'}};
		} 	
		elsif(exists($row->{$type})) {
			$args->{$target} = (exists($args->{'format'}) && ($row->{$type} ne '')) ? sprintf($args->{'format'}, $row->{$type}) : $row->{$type};
		}	
		else {
			$args->{$target} = '';
		}
		
		decode_arg($args, $row, 'caption');
		decode_arg($args, $row, 'icon');

		
		if($node->nodeName eq 'menutext') {
			$args->{'othertext'} = get_other_text($node);
		}
		
		if(($target eq 'filename') && ($args->{$target} ne '')) {			if(!($args->{$target} =~ /\.(png|jpg|aai|tbn)$/)) {
				$args->{$target}.= '.png';
			}
			if(!($args->{$target} =~ /\\/)) {
				my $sd = $type eq 'static' ? '' : $type.'\\';
				$args->{$target} = $template_dir.$sd.$args->{$target};
			}				
		}	}
	return $args;
}

sub get_default_args {
	my $pargs = shift;
	my $row = shift;

	my $args = {};

	if(exists($pargs->{'height'})) {
#		print "height: ".$args->{'height'}."\n";
		$args->{'height'} = $pargs->{'height'};
	}
	if(exists($pargs->{'width'})) {
		$args->{'width'} = $pargs->{'width'};
	}

	if(exists($pargs->{'direction'})) {
		if($pargs->{'direction'} eq 'horizontal') {
			$args->{'x'} = $pargs->{'x'} + $row->{'rownum'} * $pargs->{'spacing'};
		}
		else
		{
			$args->{'y'} = $pargs->{'y'} + $row->{'rownum'} * $pargs->{'spacing'};
		}
	}
	
	return $args;
}

sub get_other_text {
	my $node = shift;
	my $text = "";

	my @nodes = $node->parentNode->parentNode->parentNode->getChildrenByTagName('*');
	foreach my $n (@nodes) {
		my @nodes2 = $n->getChildrenByTagName('*');
		foreach my $n2 (@nodes2) {
			my @nodes3 = $n2->getChildrenByTagName('menutext');
			foreach my $n3 (@nodes3) {
				$text .= $n3->textContent.",";
			}
		}
	}
	chomp $text;
	return $text;
}

sub decode_arg {
	my $args = shift;
	my $row = shift;
	my $type = shift;

	if(exists($args->{$type}) && exists($row->{$args->{$type}})) {
		my $newtype = $args->{$type};
		$args->{$type} = (exists($args->{'format'}) && ($row->{$newtype} ne '')) ? sprintf($args->{'format'}, $row->{$newtype}) : $row->{$newtype};
		$args->{$type} .= '.aai' if $type =~ /icon/;
	}	
}

sub gettextfromtable {
	my $emm = shift;
	my $node = shift;
	my $type = shift;

	my $table = $node->getAttribute('table');
	my $rows = $node->hasAttribute('lines') ? $node->getAttribute('lines') : 99999;
	my $sep = $node->hasAttribute('separator') ? $node->getAttribute('separator') : "\n";

	$emm->clearquery($table);
	my $text ='';
	while ((my $row = $emm->next($table, '')) && $rows--) {
		$text .= $row->{$type}.$sep;
	}
	chop $text;
#	print $text."\n";
	return $text;
}