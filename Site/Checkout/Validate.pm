package Site::Checkout::Validate;

use strict;
use warnings;

use POSIX;
use Dancer qw/:syntax/;
use Dancer::Plugin::Interchange6;
use Business::CreditCard;

my $arg_class = 'Site::Checkout';

sub new {
    my $class = shift;
    my $order = shift;

    die __PACKAGE__ . " requires $arg_class object arg"
        unless ref ($order) eq $arg_class;

    my $opt = { _data => $order, _errors => {}, };

    return bless $opt, $class;
}

sub required {
    my $self = shift;
    my $node = shift or die 'require called with no param specified';
    my $msg = shift || 'blank';

    local $_ = $self->data->params->{$node} // '';

    return if length;

    return $self->errors->{$node} = $msg;
}

sub ca_postcode {
    my $self = shift;
    my $node = shift or die 'ca_postcode called with no param specified';
    my $msg = shift;

    my $val = local $_ = $self->data->params->{$node} // '';
    return unless my $err = validate_ca_postcode($val, $msg);

    return $self->errors->{$node} = $err;
}

sub validate_ca_postcode {
    my $val = shift;
    my $msg = shift || q{'%s' not a Canadian postal code};

    $val =~ s/[_\W]+//g;

    return if $val =~ /^[abceghjklmnprstvxy]\d[a-z]\d[a-z]\d$/i;
    return sprintf ($msg, $val);
}

sub zip {
    my $self = shift;
    my $node = shift or die 'zip called with no param specified';
    my $msg = shift;

    my $val = $self->data->params->{$node} // '';
    return unless my $err = validate_zip($val, $msg);

    return $self->errors->{$node} = $err;
}

sub validate_zip {
    my $val = shift;
    my $msg = shift || q{'%s' not a US zip code};

    #$val =~ s/[^\d-]+//g;

    return if $val =~ /^\d{5}(?:-?\d{4})?$/;
    return sprintf ($msg, $val);
}

sub postcode {
    my $self = shift;
    my $node = shift or die 'postcode called with no param specified';
    my $msg = shift || q{'%s' not a US or Canadian postal code};

    return unless $self->zip($node) && $self->ca_postcode($node);

    return $self->errors->{$node} = sprintf ($msg, $self->data->params->{$node});
}

sub validate_postcode {
    my $val = shift;
    my $msg = shift || q{'%s' not a US or Canadian postal code};
    return my $err = validate_zip($val,$msg) || validate_ca_postcode($val,$msg);
}

sub state_province {
    my $self = shift;
    my $node = shift or die 'state_province called with no param specified';
    my $msg = shift || q{'%s' not a %s state or province};

    my ($state_node, $country_node) = split /\s*->\s*/, $node;
    $state_node or die 'state_province called with no state_node specified';
    $country_node or die 'state_province called with no country_node specified';

    my ($s, $c) = @{ $self->data->params }{$state_node, $country_node};

    return if shop_schema
            -> resultset('State')
            -> search({
                state_iso_code => $s,
                country_iso_code => $c,
            })
            -> count > 0;

    return $self->errors->{$state_node} = sprintf ($msg, map { $_ // '(undef)' } ($s, $c));
}

sub phone {
    my $self = shift;
    my $node = shift || die 'phone called with no param specified';
    my $msg = shift || q{'%s' not a phone number};

    local $_ = $self->data->params->{$node} // '';

    # Can't say I'm on board with this test concluding "it's a phone number"
    # but making it consistent with current logic
    return if /\d{3}.*\d{3}/;

    return $self->errors->{$node} = sprintf ($msg, $_);
}

sub or {
    my $self = shift;
    my @list = @_;

    my $msg = @list % 2
        ? pop @list
        : ''
    ;

    my ($rv, $check, $node);

    while (($check, $node) = splice (@list, 0, 2)) {
        local $self->{_errors} = {};
        $rv = $self->$check($node, $msg)
            or return;
    }

    return $self->errors->{$node || 'or'} = $rv;
}

sub and {
    my $self = shift;
    my @list = @_;

    my $msg = @list % 2
        ? pop @list
        : ''
    ;

    while (my ($check, $node) = splice (@list, 0, 2)) {
        my $rv = $self->$check($node, $msg);
        return $rv if $rv;
    }

    return;
}

sub credit_card {
    my $self = shift;
    my $node = shift || 'credit_card';
    my $form = $self->data->params;

    $self->_valid_exp_date
        or return $self->errors->{$node} = 'Card expiration date invalid';

    $form->{credit_card_number} =~ s/\D+//g;
    validate($form->{credit_card_number})
        or return $self->errors->{$node} = 'Invalid credit card number';

    ($form->{credit_card_type} = cardtype($form->{credit_card_number})) =~ s/\s+card\s*$//;
    grep { $form->{credit_card_type} eq $_ } @{ config->{cards_accepted} }
        or return $self->errors->{$node} = "Sorry, we don't accept card type '$form->{credit_card_type}'";

    ($form->{credit_card_reference} = $form->{credit_card_number}) =~ s/^\d{6}\K(.*)(?=\d{4}$)/'X' x length ($1)/e;

    return;
}

sub has_items {
    my $self = shift;
    my $arg = shift;

    my $node = $arg->{node} || 'has_items';
    my $msg = $arg->{msg} || 'Cart has no items';

    my @items = $self->data->cart->products;

    return if @items;

    return $self->errors->{$node} = $msg;
}

sub cart_salable {
    my $self = shift;
    my $arg = shift;

    my $node = $arg->{node} || 'cart_salable';
    my $msg = $arg->{msg} || 'Cart contains items that cannot be sold';

    my $rs = shop_schema->resultset('Product');

    my $parent;
    return unless grep {
    # Note: "canonical" is no longer a restriction on sale
    #    ($parent = $rs->find($_->sku)->canonical) && $parent->sku eq $_->sku
    #    or
        !($rs->find($_->sku))->active
        } $self->data->cart->products_array;

    return $self->errors->{$node} = $msg;
}

sub error_count {
    return scalar keys $_[0]->errors;
}

sub errors {
    my $errors = $_[0]->{_errors};
    return %$errors if wantarray;
    return $errors;
}

sub data {
    return $_[0]->{_data};
}

sub _valid_exp_date {
    my $self = shift;
    my $form = $self->data->params;

    my $year = $form->{credit_card_exp_year};
    return unless $year =~ /^\d{4}$/;

    my $mon = $form->{credit_card_exp_month};
    return if $mon < 1 || $mon > 12;

    $form->{credit_card_exp_month} = $mon = sprintf ('%02d', $mon);

    my $customer_date = $year . $mon;

    my $now = POSIX::strftime('%Y%m', localtime);

    return $now le $customer_date;
}

1;
