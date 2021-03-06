class Cms::ContentController < Cms::ApplicationController

  rescue_from Exception, :with => :handle_server_error_on_page
  rescue_from Cms::Errors::AccessDenied, :with => :handle_access_denied_on_page
  rescue_from ActiveRecord::RecordNotFound, :with => :handle_not_found_on_page

  skip_before_filter :redirect_to_cms_site
  before_filter :construct_path
  before_filter :redirect_non_cms_users_to_public_site
  before_filter :try_to_redirect
  before_filter :try_to_stream_file
  before_filter :check_access_to_page

  def show
    render_page
    cache_page if perform_caching
  end

  def handle_not_found_on_page(exception)
    logger.warn "Page Not Found"
    handle_error_with_cms_page('/system/not_found', exception, :not_found)
  end

  def handle_access_denied_on_page(exception)
    logger.warn "Access Denied"
    handle_error_with_cms_page('/system/access_denied', exception, :forbidden)
  end

  def handle_server_error_on_page(exception)
    logger.warn "Exception: #{exception.message}\n"
    logger.warn "#{exception.backtrace.join("\n")}\n"
    handle_error_with_cms_page('/system/server_error', exception, :internal_server_error)
  end

  private
  def handle_error_with_cms_page(error_page_path, exception, status, options={})

    # If we are in the CMS, we just want to show the exception
    if perform_caching
      return handle_server_error(exception) if cms_site?
    else
      return handle_server_error(exception) if current_user.able_to?(:edit_content, :publish_content)
    end
    
    # We must be showing the page outside of the CMS
    # So we will show the error page
    if @page = Page.find_live_by_path(error_page_path)
      logger.info "Rendering Error Page: #{@page.inspect}"
      @mode = "view"
      @show_page_toolbar = false
      
      # copy new instance variables to the template
      %w[page mode show_page_toolbar].each do |v|
        @template.instance_variable_set("@#{v}", instance_variable_get("@#{v}"))
      end
      
      # clear out any content already captured 
      # by previous attempts to render the page within this request
      @template.instance_variables.select{|v| v =~ /@content_for_/ }.each do |v|
        @template.instance_variable_set("#{v}", nil)
      end
      
      render :layout => @page.layout, :template => 'cms/content/show', :status => status
    else
      handle_server_error(exception)
    end      
  end    

  def construct_path
    @paths = params[:page_path] || params[:path] || []
    @path = "/#{@paths.join("/")}"
  end
  
  def redirect_non_cms_users_to_public_site
    @show_toolbar = false
    if perform_caching
      logger.info "Caching is enabled"
      if cms_site?
        logger.info "This is the cms site"
        if current_user.able_to?(:edit_content, :publish_content)
          logger.info "User has access to cms"
          @show_toolbar = true
        else
          logger.info "User does not have access to cms"
          redirect_to url_without_cms_domain_prefix
        end
      else
        logger.info "Not the cms site"
      end
    else
      logger.info "Caching is disabled"
      if current_user.able_to?(:edit_content, :publish_content)
        @show_toolbar = true
      end
    end
    @show_page_toolbar = @show_toolbar
    true
  end
  
  def try_to_redirect
    if redirect = Redirect.find_by_from_path(@path)
      redirect_to redirect.to_path
    end    
  end

  def try_to_stream_file
    split = @paths.last.to_s.split('.')
    ext = split.size > 1 ? split.last.to_s.downcase : nil
    
    #Only try to stream cache file if it has an extension
    unless ext.blank?
      
      #Check access to file
      @attachment = Attachment.find_live_by_file_path(@path)
      if @attachment
        raise Cms::Errors::AccessDenied unless current_user.able_to_view?(@attachment)

        #Construct a path to where this file would be if it were cached
        @file = @attachment.full_file_location

        #Stream the file if it exists
        if @path != "/" && File.exists?(@file)
          send_file(@file, 
            :filename => @attachment.file_name,
            :type => @attachment.file_type,
            :disposition => "inline"
          ) 
        end    
      end
    end
    
  end

  def check_access_to_page
    set_page_mode
    if current_user.able_to?(:edit_content, :publish_content)
      @page = Page.first(:conditions => {:path => @path})
      page_not_found unless @page
    else
      @page = Page.find_live_by_path(@path)
      page_not_found unless (@page && !@page.archived?)
    end

    unless current_user.able_to_view?(@page)
      store_location
      raise Cms::Errors::AccessDenied
    end

    # Doing this so if you are logged in, you never see the cached page
    # We are calling render_page just like the show action does
    # But since we do it from a before filter, the page doesn't get cached
    if logged_in?
      logger.info "Not Caching, user is logged in"
      render_page
    elsif !@page.cacheable?
      logger.info "Not Caching, page cachable is false"
      render_page
    elsif params[:cms_cache] == "false"
      logger.info "Not Caching, cms_cache is false"
      render_page
    end

  end
  
  def render_page
    prepare_params
    render :layout => @page.layout, :action => 'show'
  end
  
  #-- Other Methods --
  
  # This method gives the content type a chance to set some params
  # This is used to make SEO-friendly URLs possible
  def prepare_params
    if params[:prepare_with] && params[:prepare_with][:content_type] && params[:prepare_with][:method]
      content_type = params[:prepare_with][:content_type].constantize
      if content_type.respond_to?(params[:prepare_with][:method])
        # This call is expected to modify params
        logger.debug "Calling #{content_type.name}.#{params[:prepare_with][:method]} prepare method"
        content_type.send(params[:prepare_with][:method], params)
      else
        logger.debug "#{content_type.name} does not respond to #{params[:prepare_with][:method]}"
      end
    else
      logger.debug "No Prepare Method"
    end    
  end
    
  def page_not_found
    raise ActiveRecord::RecordNotFound.new("No page at '#{@path}'")
  end

  def set_page_mode
    @mode = @show_toolbar && current_user.able_to?(:edit_content) ? (params[:mode] || session[:page_mode] || "edit") : "view"
    session[:page_mode] = @mode      
  end

  
end