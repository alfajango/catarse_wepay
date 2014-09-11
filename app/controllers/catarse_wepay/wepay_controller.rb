class CatarseWepay::WepayController < ApplicationController
  skip_before_filter :force_http
  SCOPE = "projects.contributions.checkout"
  layout :false

  def review
  end

  def refund
    response = gateway.call('/checkout/refund', PaymentEngines.configuration[:wepay_access_token], {
        account_id: PaymentEngines.configuration[:wepay_account_id],
        checkout_id: contribution.payment_token,
        refund_reason: t('wepay_refund_reason', scope: SCOPE),
    })

    if response['state'] == 'refunded'
      flash[:notice] = I18n.t('projects.contributions.refund.success')
    else
      flash[:alert] = refund_request.try(:message) || I18n.t('projects.contributions.refund.error')
    end

    redirect_to main_app.admin_contributions_path
  end

  def ipn
    if contribution && (contribution.payment_method == 'WePay' || contribution.payment_method.nil?)
      response = gateway.call('/checkout', PaymentEngines.configuration[:wepay_access_token], {
          checkout_id: contribution.payment_token,
      })
      PaymentEngines.create_payment_notification contribution_id: contribution.id, extra_data: response
      if response["state"]
        case response["state"].downcase
        when 'captured'
          contribution.confirm!
        when 'refunded'
          contribution.refund!
        when 'cancelled'
          contribution.cancel!
        when 'expired', 'failed'
          contribution.pendent!
        when 'authorized', 'reserved'
          contribution.waiting! if contribution.pending?
        end
      end
      contribution.update_attributes({
        :payment_service_fee => response['fee'],
        :payer_email => response['payer_email']
      })
    else
      return render status: 500, nothing: true
    end
    return render status: 200, nothing: true
  rescue Exception => e
    return render status: 500, text: e.inspect
  end

  def pay
    begin
      response = gateway.call('/checkout/create', PaymentEngines.configuration[:wepay_access_token], {
        account_id: PaymentEngines.configuration[:wepay_account_id],
        amount: (contribution.price_in_cents/100).round(2).to_s,
        short_description: t('wepay_description', scope: SCOPE, :project_name => contribution.project.name, :value => contribution.display_value),
        type: 'DONATION',
        fee_payer: ENV['WEPAY_FEE_PAYER'],
        app_fee: ENV['WEPAY_APP_FEE'],
        redirect_uri: success_wepay_url(id: contribution.id),
        callback_uri: ipn_wepay_index_url(callback_uri_params)
      })
      if response['checkout_uri']
        contribution.update_attributes payment_method: 'WePay', payment_token: response['checkout_id']
        redirect_to response['checkout_uri']
      else
        ::Airbrake.notify({ :error_class => "WePay Response Error", :error_message => "WePay Response Error: #{response.inspect}", :parameters => params}) rescue nil
        Rails.logger.info "WePay response error -----> #{response.inspect}"
        flash[:failure] = t('wepay_error', scope: SCOPE)
        return redirect_to main_app.new_project_backer_path(project_id: contribution.project.id, id: contribution.id)
      end
    rescue Exception => e
      ::Airbrake.notify({ :error_class => "WePay Error", :error_message => "WePay Error: #{e.inspect}", :parameters => params}) rescue nil
      Rails.logger.info "-----> #{e.inspect}"
      flash[:failure] = t('wepay_error', scope: SCOPE)
      return redirect_to main_app.new_project_backer_path(contribution.project)
    end
  end

  def callback_uri_params
    {host: '52966c09.ngrok.com', port: 80} if Rails.env.development?
  end

  def success
    backer = current_user.backs.find params[:id]
    response = gateway.call('/checkout', PaymentEngines.configuration[:wepay_access_token], {
        checkout_id: contribution.payment_token,
    })
    if response['state'] == 'authorized'
      flash[:success] = t('success', scope: SCOPE)
      redirect_to main_app.project_backer_path(project_id: backer.project.id, id: backer.id)
    else
      flash[:failure] = t('wepay_error', scope: SCOPE)
      redirect_to main_app.new_project_backer_path(backer.project.id, id: backer.id)
    end
  end

  def contribution
    @contribution ||= if params['id']
                  PaymentEngines.find_payment(id: params['id'])
                elsif params['checkout_id']
                  PaymentEngines.find_payment(payment_token: params['checkout_id'])
                end
  end

  def gateway
    raise "[WePay] An API Client ID and Client Secret are required to make requests to WePay" unless PaymentEngines.configuration[:wepay_client_id] and PaymentEngines.configuration[:wepay_client_secret]
    @gateway ||= WePay.new(PaymentEngines.configuration[:wepay_client_id], PaymentEngines.configuration[:wepay_client_secret], !ENV['WEPAY_USE_PRODUCTION'])
  end

end
