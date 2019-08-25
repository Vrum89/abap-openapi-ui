class ZCL_GW_OPENAPI definition
  public
  final
  create public .

public section.

  class-methods GENERATE_OPENAPI_JSON_V2
    importing
      !IV_EXTERNAL_SERVICE type /IWFND/MED_MDL_SERVICE_GRP_ID
      !IV_VERSION type /IWFND/MED_MDL_VERSION default '0001'
      !IV_BASE_URL type STRING optional
    exporting
      !EV_METADATA type XSTRING
      !EV_METADATA_STRING type STRING .
  class-methods GENERATE_OPENAPI_JSON_V4
    importing
      !IV_REPOSITORY type /IWBEP/V4_MED_REPOSITORY_ID
      !IV_GROUP_ID type /IWBEP/V4_MED_GROUP_ID
      !IV_SERVICE type /IWBEP/V4_MED_SERVICE_ID
      !IV_VERSION type /IWBEP/V4_MED_SERVICE_VERSION default '0001'
      !IV_BASE_URL type STRING
    exporting
      !EV_METADATA type XSTRING
      !EV_METADATA_STRING type STRING .
  class-methods LAUNCH_BSP
    importing
      !IV_EXTERNAL_SERVICE type /IWFND/MED_MDL_SERVICE_GRP_ID
      !IV_VERSION type /IWFND/MED_MDL_VERSION default '0001'
      !IV_REPOSITORY type /IWBEP/V4_MED_REPOSITORY_ID optional
      !IV_GROUP_ID type /IWBEP/V4_MED_GROUP_ID optional
      !IV_JSON type XFELD optional .
protected section.
private section.
ENDCLASS.



CLASS ZCL_GW_OPENAPI IMPLEMENTATION.


  METHOD GENERATE_OPENAPI_JSON_V2.
    DATA: lt_parameters     TYPE abap_trans_parmbind_tab,
          lv_version        TYPE string,
          lv_service        TYPE string,
          lv_path(255)      TYPE c,
          lv_openapi_string TYPE string.

*   Read service details
    SELECT SINGLE h~srv_identifier, h~namespace, h~service_name, h~service_version,  t~description
      FROM /iwfnd/i_med_srh AS h
      LEFT OUTER JOIN /iwfnd/i_med_srt AS t ON  h~srv_identifier = t~srv_identifier
                                            AND h~is_active      = t~is_active
                                            AND t~language       = @sy-langu
      INTO @DATA(ls_service)
      WHERE service_name = @iv_external_service
      AND service_version = @iv_version.

*   Read SICF details
    DATA(lo_icf_access) = /iwfnd/cl_icf_access=>get_icf_access( ).
    DATA(lt_icfdocu) = lo_icf_access->get_icf_docu_for_gw_libs_wo_at( ).

    LOOP AT lt_icfdocu INTO DATA(ls_icfdocu).

*     Get main odata node
      DATA(lv_icf_lib_guid) = lo_icf_access->get_node_guid_wo_at(
                                iv_icf_parent_guid = ls_icfdocu-icfparguid
                                iv_icf_node_name   = CONV icfaltnme( ls_icfdocu-icf_name )
                              ).

    ENDLOOP.

*   Get OData service URL
    TRY.
        CASE lv_icf_lib_guid.
          WHEN /iwfnd/cl_icf_access=>gcs_icf_node_ids-lib_02.
            DATA(lv_md_url) = /iwfnd/cl_med_utils=>get_meta_data_doc_url_local(
                                  iv_external_service_doc_name = ls_service-service_name
                                  iv_namespace                 = ls_service-namespace
                                  iv_icf_root_node_guid        = lv_icf_lib_guid ).

          WHEN /iwfnd/cl_icf_access=>gcs_icf_node_ids-lib_10.
            lv_md_url = /iwfnd/cl_med_utils=>get_meta_data_doc_url_local(
                            iv_external_service_doc_name = ls_service-service_name
                            iv_namespace                 = ls_service-namespace
                            iv_version                   = ls_service-service_version
                            iv_icf_root_node_guid        = lv_icf_lib_guid ).
        ENDCASE.

      CATCH /iwfnd/cx_med_mdl_access.
    ENDTRY.

*   Remove everything but path from URL
    REPLACE '/?$format=xml' IN lv_md_url WITH ''.
    DATA(lv_md_url_full) = lv_md_url.
    IF lv_md_url IS NOT INITIAL.
      DATA(lv_leng) = strlen( lv_md_url ).
      IF lv_leng > 7 AND lv_md_url(7) = 'http://'.
        SEARCH lv_md_url FOR '/sap/opu/'.
        IF sy-subrc = 0.
          lv_md_url = lv_md_url+sy-fdpos.
        ENDIF.
      ENDIF.
    ENDIF.

*   Set service
    lv_service = ls_service-namespace && ls_service-service_name.

*   Get base URL details
    IF iv_base_url IS NOT INITIAL.
      DATA(lv_base_url) = iv_base_url && lv_md_url.
    ELSE.
      lv_base_url = lv_md_url_full.
    ENDIF.

    SPLIT lv_base_url AT '://' INTO DATA(lv_scheme) DATA(lv_url_without_scheme).
    SPLIT lv_url_without_scheme AT '/' INTO DATA(lv_host) lv_path.

    DATA(lv_length) = strlen( lv_path ) - 1.
    IF lv_path+lv_length(1) = '/'.
      lv_path+lv_length(1) = ''.
    ENDIF.

*   Initialize NetWeaver Gateway transaction handler
    DATA(lo_transaction_handler) = /iwfnd/cl_transaction_handler=>get_transaction_handler( ).

    lo_transaction_handler->set_service_name( iv_name = ls_service-service_name ).
    lo_transaction_handler->set_service_version( iv_version = ls_service-service_version ).
    lo_transaction_handler->set_service_namespace( iv_namespace = ls_service-namespace ).

*   Initialize metadata access
    lo_transaction_handler->set_metadata_access_info(
      EXPORTING
        iv_load_last_modified_only = abap_true
        iv_is_busi_data_request    = abap_true
        iv_do_cache_handshake      = abap_true
    ).

*   Load metadata document
    DATA(lo_service_factory) = /iwfnd/cl_sodata_svc_factory=>get_svc_factory( ).
    DATA(lo_service) = lo_service_factory->create_service( iv_name = lv_service ).
    DATA(lo_edm) = lo_service->get_entity_data_model( ).
    DATA(lo_metadata) = lo_edm->get_service_metadata( ).

    lo_metadata->get_metadata(
      IMPORTING
        ev_metadata             = DATA(lv_xml)                 " Metadata
*    ev_data_service_version =                  " Data Service Version
    ).

*   Convert OData V2 to V4 metadata document
    CALL TRANSFORMATION zgw_odatav2_to_v4
      SOURCE XML lv_xml
      RESULT XML DATA(lv_v4).

*   Set transformation parameters
    lv_version = ls_service-service_version.
    SHIFT lv_version LEFT DELETING LEADING '0'.
    lv_version = 'V' && lv_version.

    lt_parameters = VALUE #( ( name = 'openapi-version' value = '3.0.0' )
                             ( name = 'odata-version' value = '2.0' )
                             ( name = 'scheme' value = lv_scheme )
                             ( name = 'host' value = lv_host )
                             ( name = 'basePath' value = '/' && lv_path )
                             ( name = 'info-version' value = lv_version )
                             ( name = 'info-title' value = ls_service-service_name )
                             ( name = 'info-description' value = ls_service-description )
                             ( name = 'references' value = 'YES' )
                             ( name = 'diagram' value = 'YES' ) ).

*   Convert metadata document to openapi
    CALL TRANSFORMATION zgw_odatav4_to_openapi
      SOURCE XML lv_v4
      RESULT XML DATA(lv_openapi)
      PARAMETERS (lt_parameters).

*   Convert binary data to string
    DATA(lo_conv) = cl_abap_conv_in_ce=>create(
                      EXPORTING
                        encoding    = 'UTF-8'                 " Input Character Format
                        input       = lv_openapi                 " Input Buffer (X, XSTRING)
                    ).

    lo_conv->read(
      IMPORTING
        data = lv_openapi_string
    ).

*   Add basic authentication to OpenAPI JSON
    "REPLACE ALL OCCURRENCES OF '"components":{' IN lv_openapi_string WITH '"components":{"securitySchemes":{"BasicAuth":{"type":"http","scheme":"basic"}},'.

*   Convert OpenAPI JSON to binary format
    CLEAR lv_openapi.
    CALL FUNCTION 'SCMS_STRING_TO_XSTRING'
      EXPORTING
        text   = lv_openapi_string
      IMPORTING
        buffer = lv_openapi
      EXCEPTIONS
        failed = 1
        OTHERS = 2.
    IF sy-subrc <> 0.
* Implement suitable error handling here
    ENDIF.

*   Set exporting parameters
    ev_metadata = lv_openapi.
    ev_metadata_string = lv_openapi_string.

  ENDMETHOD.


  METHOD generate_openapi_json_v4.
    DATA: lt_parameters     TYPE abap_trans_parmbind_tab,
          lv_version        TYPE string,
          lv_service        TYPE string,
          lv_path(255)      TYPE c,
          lv_openapi_string TYPE string.

*   Read service details
    SELECT SINGLE a~repository_id, a~group_id, a~service_id, s~service_version, t~description
      FROM /iwbep/i_v4_msga AS a
      INNER JOIN /iwbep/i_v4_msrv AS s ON a~service_id = s~service_id
      INNER JOIN /iwfnd/c_v4_msgr AS p ON a~group_id = p~group_id
      LEFT OUTER JOIN /iwbep/i_v4_msrt AS t ON s~service_id = t~service_id
                                            AND s~service_version = t~service_version
                                            AND t~language = @sy-langu
      INTO @DATA(ls_service)
      WHERE a~group_id = @iv_group_id
      AND a~service_id = @iv_service
      AND a~repository_id = @iv_repository
      AND s~service_version = @iv_version.

*   Set service url
    lv_service = /iwbep/cl_v4_url_util=>gc_root_url
               && ls_service-group_id && '/'
               && ls_service-repository_id && '/'
               && ls_service-service_id && '/'
               && ls_service-service_version.

    lv_service = to_lower( lv_service ).
    REPLACE ALL OCCURRENCES OF '//' IN lv_service WITH '/'.

*   Get base URL details
    DATA(lv_base_url) = iv_base_url && lv_service.

    SPLIT lv_base_url AT '://' INTO DATA(lv_scheme) DATA(lv_url_without_scheme).
    SPLIT lv_url_without_scheme AT '/' INTO DATA(lv_host) lv_path.

    DATA(lv_length) = strlen( lv_path ) - 1.
    IF lv_path+lv_length(1) = '/'.
      lv_path+lv_length(1) = ''.
    ENDIF.

*   Initialize OData context
    DATA ls_request_base_info TYPE /iwbep/if_v4_request_info=>ty_s_base_info.

    ls_request_base_info-conditions-if_modified_since = 0.
    ls_request_base_info-conditions-if_unmodified_since = 0.
    ls_request_base_info-http_method = 'GET'.
    ls_request_base_info-host_name = lv_host.
    ls_request_base_info-service_group_id = iv_group_id.
    ls_request_base_info-service_key-repository_id = iv_repository.
    ls_request_base_info-service_key-service_id = iv_service.
    ls_request_base_info-service_key-service_version = iv_version.
    ls_request_base_info-uri_request = lv_service.

    DATA(lo_request_info) = /iwbep/cl_v4s_runtime_factory=>create_request_info( ).
    lo_request_info->init( ls_request_base_info ).
    lo_request_info->set_lib_request_info( NEW /iwbep/cl_od_request_info( ) ).

    DATA(lo_context) = NEW /iwcor/cl_od_cntxt( ).
    lo_context->/iwcor/if_od_cntxt~set_object(
      EXPORTING
        iv_name   = /iwbep/if_od_types=>gc_od_cntx_object_identifier
        io_object = lo_request_info
    ).

*   Load metadata document
    DATA lo_service_factory TYPE REF TO /iwbep/cl_od_svc_factory.
    lo_service_factory ?= /iwbep/cl_od_svc_factory=>get_instance( ).
    lo_service_factory->set_lib_context( io_context = lo_context ).
    DATA(lo_service) = lo_service_factory->/iwcor/if_od_svc_factory~create_service( lv_service ).
    DATA(lo_edm) = lo_service->get_entity_data_model( ).
    DATA(lo_metadata) = lo_edm->get_service_metadata( ).

    lo_metadata->get_metadata(
      IMPORTING
        ev_metadata             = DATA(lv_xml)                 " Metadata
*    ev_data_service_version =                  " Data Service Version
    ).

*   Set transformation parameters
    lv_version = ls_service-service_version.
    SHIFT lv_version LEFT DELETING LEADING '0'.
    lv_version = 'V' && lv_version.

    lt_parameters = VALUE #( ( name = 'openapi-version' value = '3.0.0' )
                             ( name = 'odata-version' value = '4.0' )
                             ( name = 'scheme' value = lv_scheme )
                             ( name = 'host' value = lv_host )
                             ( name = 'basePath' value = '/' && lv_path )
                             ( name = 'info-version' value = lv_version )
                             ( name = 'info-title' value = ls_service-service_id )
                             ( name = 'info-description' value = ls_service-description )
                             ( name = 'references' value = 'YES' )
                             ( name = 'diagram' value = 'YES' ) ).

*   Convert metadata document to openapi
    CALL TRANSFORMATION zgw_odatav4_to_openapi
      SOURCE XML lv_xml
      RESULT XML DATA(lv_openapi)
      PARAMETERS (lt_parameters).

*   Convert binary data to string
    DATA(lo_conv) = cl_abap_conv_in_ce=>create(
                      EXPORTING
                        encoding    = 'UTF-8'                 " Input Character Format
                        input       = lv_openapi                 " Input Buffer (X, XSTRING)
                    ).

    lo_conv->read(
      IMPORTING
        data = lv_openapi_string
    ).

    REPLACE ALL OCCURRENCES OF ',,' IN lv_openapi_string WITH ''.
    "REPLACE ALL OCCURRENCES OF 'com.sap.gateway.default.iwngw.notification_srv.v0001.' IN lv_openapi_string WITH ''.

*   Add basic authentication to OpenAPI JSON
    "REPLACE ALL OCCURRENCES OF '"components":{' IN lv_openapi_string WITH '"components":{"securitySchemes":{"BasicAuth":{"type":"http","scheme":"basic"}},'.

*   Convert OpenAPI JSON to binary format
    CLEAR lv_openapi.
    CALL FUNCTION 'SCMS_STRING_TO_XSTRING'
      EXPORTING
        text   = lv_openapi_string
      IMPORTING
        buffer = lv_openapi
      EXCEPTIONS
        failed = 1
        OTHERS = 2.
    IF sy-subrc <> 0.
* Implement suitable error handling here
    ENDIF.

*   Set exporting parameters
    ev_metadata = lv_openapi.
    ev_metadata_string = lv_openapi_string.

  ENDMETHOD.


  METHOD launch_bsp.
    DATA: lv_url    TYPE string,
          lv_url_1  TYPE agr_url2,
          lv_appl   TYPE string,
          lv_page   TYPE string,
          lt_params TYPE tihttpnvp.

*   Set parameters for BSP application
    lt_params = VALUE #( ( name = 'service' value = iv_external_service )
                         ( name = 'version' value = iv_version )
                         ( name = 'repository' value = iv_repository )
                         ( name = 'group' value = iv_group_id )
                         ( name = 'sap-client' value = sy-mandt )
                         ( name = 'sap-language' value = sy-langu ) ).

*   Set page
    IF iv_json = abap_false.
      lv_page = 'index.html'.
    ELSE.
      lv_page = 'openapi.json'.
    ENDIF.

*   Generate URL for BSP application
    CALL METHOD cl_http_ext_webapp=>create_url_for_bsp_application
      EXPORTING
        bsp_application      = 'ZGW_OPENAPI'
        bsp_start_page       = lv_page
        bsp_start_parameters = lt_params
      IMPORTING
        abs_url              = lv_url.

*   Launch BSP application
    lv_url_1 = lv_url.

    CALL FUNCTION 'CALL_BROWSER'
      EXPORTING
        url                    = lv_url_1
*       BROWSER_TYPE           =
*       CONTEXTSTRING          =
      EXCEPTIONS
        frontend_not_supported = 1
        frontend_error         = 2
        prog_not_found         = 3
        no_batch               = 4
        unspecified_error      = 5
        OTHERS                 = 6.

  ENDMETHOD.
ENDCLASS.