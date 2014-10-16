package Site::Checkout;

=head1 NAME

Site::Checkout

=head1 DESCRIPTION

Handles the actions from profile and log_transaction from the IC5 catalog.

=head1 USAGE

 my $checkout = Site::Checkout->new_order($cart, $params);
 
 # Log initial state of order when received
 $checkout->track_order(file => 'PRE-' . $checkout->order_number);
 
 # Validate
 if (my $err = $checkout->validate_order) {
     printf "We have %d errors!\n", $err->error_count;
     while (my ($field, $msg) = each $err->errors) {
         print "* $field: $msg\n";
     }
     return; # because form input is bad and user needs to try again
 }
 
 # Process payment
 if (my $err = $checkout->process_payment) {
     print "Sorry, we received the following credit card error: $err\n";
     return; # so user can try a different credit card
 }
 
 # All clear! Write the order to the database
 if (my $err = $checkout->finalize_order) {
     print 'A system error occurred when processing your order. '
         . 'Please contact customer service at __PHONE__ to complete your order. '
         . "(Error report: $err)";
 
     # Let's track the current order state to give us something to look for.
     # Includes the DBIC database objects.
     $checkout->track_order(file => 'ERR-' . $checkout->order_number);
 
     return; # because we have no idea what blew up, or why
 }
 
 # We have a successful order, logged to the database.
 # Optionally track the completed form of the order as it may
 # contain useful information not present in the database
 $checkout->track_order(file => 'POST-' . $checkout->order_number);
 
 return 1;

=head1 METHODS

=cut

use strict;
use warnings;
use Business::OnlinePayment;
use Dancer ':syntax';
use Dancer::Plugin::Auth::Extensible;
use Dancer::Plugin::Interchange6;
use Dancer::Plugin::DBIC qw(schema resultset rset);
use Site::Checkout::Promo;
use Site::Checkout::Validate;
use Site::Util qw(local_log);
use Util::Logger;
use POSIX qw();
use JSON qw();
use DBI;
use DBD::Pg;
use Try::Tiny;
use Mail::Mailer;
use Hash::Merge::Simple qw();

our $VERSION = '0.1';

my @accessors = qw/
    cart
    params
    order_number
    dbh
    gateway
    payment
    order
    processor
/;

=head2 new_order($cart, $params)

 * $cart is an Interchange6::Cart (?)
 * $params is a hashref with all form inputs

 Constructor. Returns Site::Checkout object.

=cut

sub new_order {
    my $class = shift;
    my $self = bless {}, $class;

    return $self->_init(@_);
}

sub _init {
    my $self = shift;

    $self->cart(shift);
    $self->params(shift);
    $self->dbh(shop_schema->storage->dbh);
    $self->order_number($self->dbh->selectrow_array(q{SELECT NEXTVAL('orders_orders_id_seq')}));
    $self->processor($self->_config_merge('gateway')->{processor});
    $self->gateway(Business::OnlinePayment->new($self->processor));

    return $self;
}

=head2 track_order(%opt)

 * $opt{file} is required. Will place file under config->{logdir} . config->{track_order}{dir}
 * $opt{quiet} will suppress all output so logging can be disabled without commenting/removing log statements
 * $opt{anchor} will plug in common begin string for all log entries (default order_number)
 * $opt{serializer} - one of YAML (default), JSON, Data::Dumper
 * $opt{ts_fmt} sets strftime() format of timestamps (default %FT%T%z)

 Normally only need to set 'file'.

=cut

sub track_order {
    my $self = shift;
    my %opt = @_;

    # Requires: file.
    # Opt: serializer (defaults to YAML, can be YAML, JSON, or Data::Dumper)
    #      quiet (so can disable based DEVELOPMENT, e.g.)
    #           for other stuff, see Util::Logger
    $opt{file}
        or die "track_order() called with no file specified for tracking";

    # Put in its own special directory
    $opt{file} = config->{track_order}{dir} . $opt{file};

    # Using YAML because it's clean, compact, and doesn't choke on objects!
    $opt{serializer} ||= 'YAML';

    # Regexes to scrub out sensitive keys. Format depends on serializer chosen!
    $opt{scrub} ||= [ qr/(?:login|password|card_number|cvv2): \K(.*)/m ];

    $opt{anchor} //= $self->order_number;

    # Record the entire Site::Checkout object.
    Util::Logger
        -> new(%opt)
        -> logf('%s', $self)
    ;

    return;
}

=head2 validate_order()

 Creates Site::Checkout::Validate object that has as methods the typical
 checks you find in Interchange 5 profiles:

 * required('field')
 * ca_postcode('field')
 * zip('field')
 * postcode('field')
    - combines previous two tests to match either/or
 * state_province('statefield->countryfield')
 * phone('field')
 * or(check1 => 'field1', check2 => 'field2', ...)
    - passes if any pass or returns error in node of final check
 * and(check1 => 'field1', check2 => 'field2', ...)
    - passes if all pass or returns error in node of first failed check (and short-circuits)
 * credit_card('node')
    - does roughly the validation of &credit_card, with no encryption.
    - places error into hash key 'node', or 'credit_card' by default.
    - places some calculated values back into $params hash:
      + credit_card_type
      + credit_card_reference
 * has_items('node')
    - ensures cart has at least one item.
    - places error into hash key 'node', or 'has_items' by default.
 * cart_salable('node')
    - ensures cart has no items with is_canonical flag.
    - places error into hash key 'node', or 'cart_salable' by default.

 Returns Site::Checkout::Validate object on failure, against which
 the error_count() and errors() methods can be called to work with those data.

=cut

sub validate_order {
    my $self = shift;

    # Validation occurs here. Are the various fields of the proper type and format?
    # Does the order represent actual products which are available for sale?
    # And lots of other stuff.

    # All tests return the error string if there is an error.
    # Object collects all errors that can be tested for by checking
    # $val->error_count. Errors can then be retrieved as a hash
    # via $val->errors in list context, or the hash ref in scalar
    # context.
    my $val = Site::Checkout::Validate->new($self);

    # Make sure cart isn't empty
    $val->has_items({ node => 'items', });

    # Check if cart has any stub items which can't be sold
    $val->cart_salable({ node => 'items', });

    # Tests from profiles.order
    $val->required('first_name');
    $val->required('last_name');
    $val->required('address');
    $val->required('city');
    $val->required('country');

    # US/CA only
    if ($self->params->{country} =~ /^(?:US|CA)$/) {
        $val->state_province('state->country');
        $val->postcode('postal_code');
    }

    # Promo code if present
    if ($self->params->{promo_code} =~ /\w/) {
        my $err = Site::Checkout::Promo::validate_promo($self->params->{promo_code}, $self);
        if ($err) {
            $val->errors->{promo_code} = $err;
        }
    }

    # Error is set in last node specified (i.e., phone below)
    $val->or(phone => 'phone_night', phone => 'phone', 'Must have day or evening phone number');

    # Setting &fatal here
    return $val if $val->error_count;

    # Tests post &fatal, one and done
    $val->credit_card
        and return $val;

    # All good!
    return;
}

=head2 process_payment()

 Uses Business::OnlinePayment to run credit card transactions.

 Creates record in payment_orders table, success or failure. Allows
 for combining gateway_log and payments into one table as is clearly
 intended for IC 6.

 Set parameters for the transaction in config:
 * config->{gateway}{processor}
    - must correspond to the BOLP gateway-specific module extension
    - e.g., AuthorizeNet
 * under processor:
    - config->{gateway}{AuthorizeNet}{id}
    - config->{gateway}{AuthorizeNet}{password}
    - config->{gateway}{AuthorizeNet}{transaction}
      + 'Normal Authorization', 'Pre Authorization', etc.

 Returns error from payment gateway on failure.

=cut

sub process_payment {
    my $self = shift;
    my $gw = $self->gateway;

    $gw->test_transaction($self->_config_merge('gateway')->{testmode});
    $gw->require_avs(1);

    my $processor = $self->_config_merge('gateway')->{$self->processor};

    my %content = (
        type           => 'CC',
        login          => $processor->{id},
        password       => $processor->{password},
        action         => $processor->{transaction},
        description    => sprintf ('Order %s', $self->order_number),
        amount         => $self->cart->total,
        invoice_number => $self->order_number,
        first_name     => $self->params->{first_name},
        last_name      => $self->params->{last_name},
        address        => $self->params->{address},
        city           => $self->params->{city},
        state          => $self->params->{state},
        zip            => $self->params->{postal_code},
        email          => logged_in_user->email,
        card_number    => $self->params->{credit_card_number},
        expiration     => sprintf ('%s/%s', @{ $self->params }{qw/credit_card_exp_month credit_card_exp_year/}),
        cvv2           => $self->params->{credit_card_cvv2},
    );

    $gw->content(%content);
    $gw->submit;

    RECORD: {
        my %request = %content;
        $request{card_number} = $self->params->{credit_card_reference};
        for (qw/login password cvv2/) {
            $request{$_} &&= 'X' x length ($request{$_} || '');
        }

        # Not clear all these methods documented for BOLP are implemented
        # for BOLP-AuthorizeNet.
        my %response =
            map
                { ( $_ => $gw->can($_) ? $gw->$_ : 'undefined routine' ) }
                qw/
                    is_success
                    error_message
                    failure_status
                    authorization
                    order_number
                    response_code
                    response_page
                    result_code
                    avs_code
                    cvv2_response
                /
        ;

        $self->payment(
            shop_schema->resultset('PaymentOrder')->create({
                payment_mode => $self->processor,
                payment_action => $gw->transaction_type,
                payment_id => $gw->order_number // '',
                auth_code => $gw->authorization || '',
                users_id => logged_in_user->users_id,
                sessions_id => session->id,
                amount => $content{amount},
                status => $gw->is_success ? 'success' : 'failed',
                payment_error_code => $gw->result_code || '',
                payment_error_message => $gw->error_message || '',
                request => $self->_json->encode(\%request),

                # Dug server_response() out of code read. Testing in case it disappears
                # or a new payment gateway is used
                response => $gw->can('server_response') && $gw->server_response || $self->_json->encode(\%response),

                avs_result => $gw->avs_code || '',
                cvv2_result => $gw->cvv2_response || '',
            })
        );
    }

    return if $gw->is_success;

    return $gw->error_message || 'Unknown error processing credit card';
}

=head2 finalize_order()

 Writes order and orderlines to database.

 Stores DBIC order and orderlines into object, accessible from
 order() and orderlines() methods.

 Updates payment record to include the successful order number.

 Returns error interacting with database on failure.

=cut

sub finalize_order {
    my $self = shift;

    # Finalize the order now that it has been paid for. I.e., transform it into a paid,
    # shippable order.

    my ($order, @ol);

    my $err;
    #for (qw/shipping handling salestax discount/) {
    #    debug "$_: ", $self->cart->cost($_);
    #}
    #for (qw/subtotal total/) {
    #    debug "$_: ", $self->cart->$_;
    #}
    try {

        shop_schema->txn_do(sub {

            # Create orders record
            my $order = shop_schema->resultset('Order')->new({
                orders_id => $self->order_number,
                order_number => $self->order_number,
                order_date => POSIX::strftime('%Y-%m-%d %T', localtime),
                users_id => logged_in_user->users_id,
                email => logged_in_user->email,
                billing_addresses_id  => $self->params->{billing_addresses_id},
                shipping_addresses_id => $self->params->{shipping_addresses_id},
                payment_method => sprintf ('%s - %s', $self->processor, $self->params->{credit_card_type}),
                payment_status => $self->gateway->transaction_type eq 'Authorization Only' ? 'pending' : 'paid',
                shipping_method => $self->params->{shipping_method},
                subtotal => $self->cart->subtotal // 0,
                shipping => $self->cart->cost('shipping') // 0,
                handling => $self->cart->cost('handling') // 0,
                salestax => $self->cart->cost('salestax') // 0,
                discount => abs($self->cart->cost('discount') // 0),
                weight   => Site::Cart::calc_weight($self->cart),
                total_cost => $self->cart->total // 0,
                status => 'pending', # no idea on status here
            });

            $order->insert;

            $self->order($order);

            # Add orderlines
            my $position = 0;
            for my $item ($self->cart->products_array) {
                $self->orderlines(
                    shop_schema->resultset('Orderline')->create({
                        orders_id => $order->orders_id,
                        order_position => ++$position,
                        sku => $item->sku,
                        name => $item->product->first->name,
                        short_description => $item->product->first->short_description,
                        description => $item->product->first->description,
                        weight => $item->product->first->weight,
                        quantity => $item->quantity,
                        price => $item->price,
                        subtotal => $item->price * $item->quantity,
                    })
                );
            }

                                # And add order number to successful payment record
            $self->payment->orders_id($order->orders_id);
            $self->payment->update;
        });
    }
    catch {
        $err = $@;
    };

    return $err;
}

=head2 send_receipt()

 Constructs email receipt and sends to email address associated with the user
 (or an override value).

 Set override in config or environment file:
  email_override: yourname@yoursite.com

 Returns error interacting with database or email agent on failure.


=cut

sub send_receipt {
    my $self = shift;
    my %args = @_;
    my $to_addr =
        config->{email}{override} //
        $args{email} //
        $self->order->email;

    return 'No email address for receipt' unless $to_addr;
    my $from_addr = config->{receipts_from};

    my $order;
    eval {
        # Because this senses "wantarray" now.
        my $desc = Site::Cart::code_to_method($self->order->shipping_method);
        $order = shop_schema->resultset('Order')->find($self->order->id);
        my $context = {
            map { 'has_' . $_ => $order->$_ != 0 } qw/discount handling salestax shipping/,
        };
        my $email_body = template 'receipt',
            { order => $order,
              not_email => 0,
              %$context,
              #additional_scripts => [ ],
              #additional_styles => [ ],
              shipping_method_desc => $desc,
            }, { layout => 'simple' };
        #Dancer::debug('email body has ', length($email_body), ' chars, looks like "', substr($email_body,0,100), '...');
        if (config->{checkout}{log_receipt}) {
            local_log('receipt/' . $order->order_number, $email_body);
        }
        my $header = {
            To      => $to_addr,
            From    => $from_addr,
            Subject => sprintf('Site Order #%s', $order->order_number),
            'Content-Type' => 'text/html',
        };
        my $mailer = Mail::Mailer->new();
        $mailer->open( $header ) or die $!;
        binmode $mailer, ":encoding(UTF-8)";
        $email_body =~ s/&amp;/&/g;
        print $mailer $email_body;
        my $status = $mailer->close;
        #debug $!;
        die "Mailer failed: $!" unless $! =~ /(?:illegal seek)|(?:inappropriate ioctl)/i;
        Dancer::debug('mail sent!');
    };
    return $@;
}

sub orderlines {
    my $self = shift;

    my $arr = $self->{_orderlines} ||= [];

    if (@_) {
        # Clear storage by sending non-reference arg
        unless (ref $_[0]) {
            @$arr = ();
        }
        # Plug in remaining list, without checking. This ain't Moose here, so don't screw it up!
        else {
            push (@$arr, @_);
        }
    }

    return @$arr if wantarray;
    return scalar @$arr;
}

sub _json {
    shift->{__json} ||= JSON->new->pretty(1);
}

sub _config_merge {
    my $self = shift;
    my $key = shift;

    my $rh = $self->{"_config_merge_$key"}
        ||= ref (config->{$key . '_local'}) eq 'HASH'
            ? Hash::Merge::Simple::merge(config->{$key}, config->{$key . '_local'})
            : config->{$key}
    ;

    return $rh;
}

ACCESSORS: {

    local $@;

    my $template = q|
        sub %1$s {
            my $self = shift;
            $self->{_%1$s} = shift
                if @_;
            return $self->{_%1$s};
        }
    |;

    my $eval = '';
    $eval .= sprintf ($template, $_)
        for @accessors;

    eval $eval;
    die $@ if $@;
}

sub shipping_address {
    my $self = shift;
    if ($self->order) {
        return $self->order->shipping_address;
    }
    else {
        return shop_schema->resultset('Address')->find($self->params->{shipping_addresses_id});
    }
}

=head1 ACCESSORS

 * cart() - cart supplied at creation
 * params() - params supplied at creation, supplemented by validation routine
 * order_number() - value grabbed from nextval() on orders PK sequence
 * dbh() - if you need the DBI database handle.
 * gateway() - Business::OnlinePayment::AuthorizeNet object.
 * payment() - DBIC for the payment row in payment_orders table.
 * order() - DBIC for the order row in orders table.
 * orderlines() - Array of DBIC for the orderlines rows for the order. Size of array in scalar.
 * processor() - Which Business::OnlinePayment processor we're configured to use (currently AuthorizeNet).

=cut

1;
