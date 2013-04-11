package ReverseProxy::FormFiller;

use strict;
use Apache2::Filter;
use Apache2::Const -compile => qw(:common);
use Apache2::RequestUtil;
use Apache2::RequestRec;
use Apache2::Log;
use URI::Escape;

our $VERSION = '0.2';

my $globalParams;

sub logError {
    my ($r, $error) = @_;
    $r->log->error("ReverseProxy::FormFiller is not configured, since $error");
}

sub getParams {
    my $r = shift;
    my $paramFile = $r->dir_config('FormFillerParamFile');
    unless (defined $paramFile) {
        &logError($r, "there is no perl var FormFillerParamFile defined in Apache config");
        return 0;
    }
    unless (defined $globalParams->{$paramFile}) {
        if (open F, $paramFile) {
            local $/ = undef;
            my $paramContent = <F>;
            close F;
            my $params;
            eval "\$params = {$paramContent}";
            if ($@) {
                &logError($r, "$paramFile content doesn't seem to be a valid perl hash");
                $globalParams->{$paramFile} = 0;
            } else {
                $params->{form}   ||= 'form:first';
                $params->{submit} ||= 'false';
                $params->{secretFormData} ||= {};
                $params->{publicFormData} ||= {};
                %{ $params->{secretFormData} } = (
                    %{ $params->{publicFormData} },
                    %{ $params->{secretFormData} }
                );
                $globalParams->{$paramFile} = $params;
            }
        } else {
            &logError($r, "Apache can't read $paramFile");
            $globalParams->{$paramFile} = 0;
        }
    }
    return $globalParams->{$paramFile};
}

## forge javascript to fill and submit form
sub js {
    my $params = shift;
    my ($form, $submit) = ($params->{form}, $params->{submit});
    eval "\$form = $form";
    eval "\$submit = $submit";
    my $js = "  var form = jQuery('$form')\n"
           . "  form.attr('autocomplete', 'off')\n";
    while ( my ($name, $value) = each %{ $params->{publicFormData} } ) {
        eval "\$value = $value";
        $js .= "  form.find('input[name=$name], select[name=$name], textarea[name=$name]').val('$value')\n";
    }
    $js .= $submit eq "true"  ? "  form.submit()\n"
         : $submit ne "false" ? "  form.find('$submit').click()\n"
         : "";
    $js = "<script type='text/javascript'>\n"
        . "/* script added by ReverseProxy::FormFiller */\n"
        . "jQuery(window).load(function() {\n$js})\n"
        . "</script>\n";
    $js = "<script type='text/javascript' src='$params->{jQueryUrl}'></script>\n$js"
        if ($params->{jQueryUrl});
    return $js;
}

## filter applied to response body
sub output {
    my $f = shift;
    my $buffer;
    my $params = &getParams($f->r);

    # Filter only html reponse body
    unless (
        (!defined $f->r->content_type or $f->r->content_type =~ /html/i)
      && $params
    ) {
        $f->print($buffer) while ($f->read($buffer));
        return Apache2::Const::OK;
    }

    my $body = $f->ctx || "";
    $body .= $buffer while ($f->read($buffer));
    unless ($f->seen_eos) {
        $f->ctx($body);
    } else {
        $f->r->subprocess_env;
        my $js = &js($params);
        $body =~ s/(<\/head>)/$js$1/i or $body =~ s/(<body>)/$1$js/i;
        $f->print($body);
    }
    return Apache2::Const::OK;
}

## filter applied to request body
sub input {
    my $f = shift;
    my $buffer;
    my $params = &getParams($f->r);

    # Filter only POST request body
    unless ($f->r->method eq "POST" && $params) {
        $f->print($buffer) while ($f->read($buffer));
        return Apache2::Const::OK;
    }

    my $body = $f->ctx || "";
    $body .= $buffer while ($f->read($buffer));
    unless ($f->seen_eos) {
        $f->ctx($body);
    } else {
        $f->r->subprocess_env;
        while ( my ($name, $value) = each %{ $params->{secretFormData} } ) {
            eval "\$value = $value";
            $name  = uri_escape $name;
            $value = uri_escape $value;
            $body =~ s/$name=.*?((?:&|$))/$name=$value$1/;
        }
        $f->print($body);
    }
    return Apache2::Const::OK;
}

1;

__END__
=head1 NAME

ReverseProxy::FormFiller - Let Apache fill and submit any html form in place of the user

=head1 VERSION

Version 0.2

=head1 SYNOPSIS

ReverseProxy::FormFiller makes an Apache server, positioned as a frontal server or as a reverse-proxy, fill and (possibly) submit html forms in place of users.

This is particularly intended for authentication forms, if you want users to be authenticated with some account, but if you don't want them to know and type any password. But it also works with any html POST form.

ReverseProxy::FormFiller is based on Apache2 mod_perl filters. So, you have to enable mod_perl.

=head2 Basic Example

Assume you want all users requesting auth.example.com to be authenticated as "jdoe", but you don't want to publish jdoe's password.
If auth.example.com's authentication form is located at http://auth.example.com/login.php and looks like

  <form id="authForm" method="POST" action="/login/">
    <div>login: <input type="text" name="login"></div>
    <div>password: <input type="password" name="password"></div>
    <div><input type="submit" value="Log in"></div>
  </form>

create an Apache virtualhost called myauth.example.com, looking like :

  <VirtualHost *>
    ServerName myauth.example.com

    PerlModule ReverseProxy::FormFiller
    PerlSetVar FormFillerParamFile "/etc/apache2/FormFiller/example"

    ProxyPass        / http://auth.example.com/
    ProxyPassReverse / http://auth.example.com/

    <Location /login.php>
      RequestHeader unset Accept-Encoding
      Header        unset Content-Length
      PerlOutputFilterHandler ReverseProxy::FormFiller::output
    </Location>

    <Location /login/>
      PerlInputFilterHandler  ReverseProxy::FormFiller::input
    </Location>
  </VirtualHost>

and create a ReverseProxy::FormFiller config file at /etc/apache2/FormFiller/example, looking like

  form   => '#authForm',
  submit => "true",
  publicFormData => {
    login    => "jdoe",
    password => "fake",
  },
  secretFormData => {
    password => "secret",
  },


=head2 Elaborate example

Assume you want some people to be authenticated as "user", and some other as "admin".

Besides, assume just submit form does not work, but it is necessary to click on the button, since it will execute a javascript function.

Finally, assume jQuery is not loaded by the web page displaying the form.

/etc/apache2/FormFiller/example will look like

  jQueryUrl => 'http://ajax.googleapis.com/ajax/libs/jquery/1/jquery.min.js',
  form   => '#authForm',
  submit => "button[type=submit]",
  publicFormData => {
    login    => '$ENV{REMOTE_USER} =~ /(rtyler|msmith)/ ? "admin" : "user"',
    password => "fake",
  },
  secretFormData => {
    password => '$ENV{REMOTE_USER} =~ /(rtyler|msmith)/ ? "admin-secret" : "user-secret"',
  },


=head2 Screwy example

Assume you have two authentication forms in the same page, one for the morning and another one for the afternoon :

/etc/apache2/FormFiller/example will look like

  form   => '(localtime)[2] >= 12 ? "#morningForm" : "#afternoonForm"',
  submit => "false",
  publicFormData => {
    login    => "jdoe", # so, user believe he'll be authenticated as "jdoe"
    password => "fake",
  },
  secretFormData => {
     # but actually, he'll be authenticated as "admin" or as "user"
    login    => '$ENV{REMOTE_USER} =~ /(rtyler|msmith)/ ? "admin" : "user"',
    password => '$ENV{REMOTE_USER} =~ /(rtyler|msmith)/ ? "admin-secret" : "user-secret"',
  },


=head1 Details of Apache config

=head2 Load Module

This is done by

  PerlModule ReverseProxy::FormFiller

This directive has to appear once in Apache config.
It can be set in server config or in a <VirtualHost> container.

=head2 Set config parameters

This is done by

  PerlSetVar FormFillerParamFile "/etc/apache2/FormFiller/example"

This directive can be set in server config or in a any container directive (as a <VirtualHost> container, a <Location> container or a <Directory> container). It is applied only to requests matching the corresponding container directive.

This directive can be set several times, so a single server can manage several forms (typically, on different virtualhosts, but you can also manage several forms in the same virtualhost).

=head2 Filter response body

When Apache has received the response from the remote server (if Apache is used as a reverse-proxy) or from the backend server (if used as a frontend), it rewrites html so as to fill the form and possibly submitting it or clicking on a button.

Actually, this is done not by directly overwriting the form, but by including some javascript filling and submitting the form.

This is done by the directive

  PerlOutputFilterHandler ReverseProxy::FormFiller::output

Besides, ReverseProxy::FormFiller::output can not (or not yet) read zipped contents, so HTTP request headers "Content-encoding" have to be removed. This is done by the directive

  RequestHeader unset Accept-Encoding

And ReverseProxy::FormFiller::output can not (or not yet) set Content-Length response header to the modified response body's length. So, remove Content-Length response header to avoid some bugs:

  Header unset Content-Length

For performances, it is better to handle only html pages containing the aimed form. So, you should place these directives in a container directive matching the form URL (as a <Location> directive), so as not to filter any html content.

=head2 Filter request body

When Apache receives a POST request from a client, it rewrites request POST body, replacing empty or fake data with secret data. This is done by the directive

  PerlInputFilterHandler  ReverseProxy::FormFiller::input

For performances, it is better to handle only requests to the form "action" URL. So, you should place this directive in a container directive matching this URL (as a <Location> directive), so as not to filter any request.

=head1 ReverseProxy::FormFiller config parameters

ReverseProxy::FormFiller config file looks similar to a .ini file, but it is not. Actually it is simply a hash content. So, don't forget commas !
In case of syntax error, you'll have a message "<config file> content doesn't seem to be a valid perl hash" in Apache error logs.

=head2 jQueryUrl

URL to load jQuery, since ReverseProxy::FormFiller response filter relies on jQuery (any version >= 1.0)
Optional: if empty or not defined, jQuery is supposed to be already loaded in the web page

=head2 form

jQuery selector to the form to fill.
For example :

  form => "form#authForm",

or

  form => "form:last",

Optional: if empty or not defined, first form in web page will be filled - i.e.,

  form => "form:first",

This field may rely on perl functions and Apache environment vars, e.g

  form => '(localtime)[2] >= 12 ? "#morningForm" : "#afternoonForm"',

or

  form => '$ENV{REMOTE_USER} =~ /(rtyler|msmith)/ ? "#adminForm" : "#userForm"',

=head2 submit

To enable form autosubmit, or to automatically click on a button.

It may be "true" (autosubmit enabled), "false" (autosubmit disabled), or a jQuery selector to the button to click on (this is sometimes useful, when clicking runs a javasript function). It also may rely on perl functions and Apache environment vars (as same as "form" parameter).

Optional: if empty or not defined, autosubmit is disabled - that is, default value is "false".

For example,

  submit => "true",

or
  submit => 'button#login',

=head2 publicFormData

Form fields to fill in html form : these data will be seen by user.

Additionnaly, these fields will be controled in POST request when the form will be submitted, to prevent malicious users to change any value.

As same as "submit" and "form" parameters, field values can rely on perl functions and Apache environment vars.

For example,

  publicFormData => {
    company  => "SnakeOilsInc",
    user     => '$ENV{REMOTE_USER} =~ /(rtyler|msmith)/ ? "admin" : "user"',
    password => "hidden"
  },

Note that these data are filled through jQuery method '.val()', so it works only with text inputs, password inputs, select tags and textarea, but not with checkbox and radio buttons.

But all inputs

=head2 secretFormData

Form fields to fill in request body, in addition or in overload to publicFormData. The main with between publicFormData is that these data will not be filled in the html form, so users can't see them.

Field values can rely on perl functions and Apache environment vars.

  secretFormData => {
    password => '$ENV{REMOTE_USER} =~ /(rtyler|msmith)/ ? "admin-secret" : "user-secret"',
  },

=head1 AUTHOR

FX Deltombe, C<< <fxdeltombe at gmail.com> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-reverseproxy-formfiller at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=ReverseProxy-FormFiller>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc ReverseProxy::FormFiller


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=ReverseProxy-FormFiller>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/ReverseProxy-FormFiller>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/ReverseProxy-FormFiller>

=item * Search CPAN

L<http://search.cpan.org/dist/ReverseProxy-FormFiller/>

=back


=head1 ACKNOWLEDGEMENTS


=head1 LICENSE AND COPYRIGHT

Copyright 2013 FX Deltombe.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.
