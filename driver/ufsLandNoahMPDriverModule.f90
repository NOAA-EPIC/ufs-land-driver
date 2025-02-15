module ufsLandNoahMPDriverModule

implicit none

contains

subroutine ufsLandNoahMPDriverInit(namelist, static, forcing, noahmp)

  use NamelistRead
  use ufsLandNoahMPType
  use ufsLandStaticModule
  use ufsLandInitialModule
  use ufsLandForcingModule
  use ufsLandNoahMPRestartModule

  implicit none

  type (namelist_type)       :: namelist
  type (noahmp_type)         :: noahmp
  type (static_type)         :: static
  type (initial_type)        :: initial
  type (forcing_type)        :: forcing
  type (noahmp_restart_type) :: restart

  call static%ReadStatic(namelist)
  
  call noahmp%Init(namelist,namelist%subset_length)

  if(namelist%restart_simulation) then
    call restart%ReadRestartNoahMP(namelist, noahmp)
  else
    call initial%ReadInitial(namelist)
    call initial%TransferInitialNoahMP(namelist, noahmp)
  end if
  
  call static%TransferStaticNoahMP(noahmp)
  
  call noahmp%TransferNamelist(namelist)
  
  call forcing%ReadForcingInit(namelist)
  
end subroutine ufsLandNoahMPDriverInit
  
subroutine ufsLandNoahMPDriverRun(namelist, static, forcing, noahmp)

use machine , only : kind_phys
use noahmpdrv
use set_soilveg_mod
use funcphys
use namelist_soilveg, only : z0_data
use physcons, only : con_hvap , con_cp, con_jcal, con_eps, con_epsm1,    &
                     con_fvirt, con_rd, con_hfus, con_g  ,               &
		     tfreeze=> con_t0c, rhoh2o => rhowater

use interpolation_utilities
use time_utilities
use cosine_zenith
use NamelistRead, only         : namelist_type
use ufsLandNoahMPType, only    : noahmp_type
use ufsLandStaticModule, only  : static_type
use ufsLandForcingModule
use ufsLandIOModule
use ufsLandNoahMPRestartModule

type (namelist_type)  :: namelist
type (noahmp_type)    :: noahmp
type (forcing_type)   :: forcing
type (static_type)    :: static
type (output_type)    :: output
type (noahmp_restart_type)    :: restart

integer          :: timestep
double precision :: now_time
character*19     :: now_date  ! format: yyyy-mm-dd hh:nn:ss
integer          :: now_yyyy

integer                            :: itime      ! not used
integer                            :: errflg     ! CCPP error flag
character(len=128)                 :: errmsg     ! CCPP error message
   real, allocatable, dimension(:) :: rho        ! density [kg/m3]
   real, allocatable, dimension(:) :: u1         ! u-component of wind [m/s]
   real, allocatable, dimension(:) :: v1         ! v-component of wind [m/s]
   real, allocatable, dimension(:) :: snet       ! shortwave absorbed at surface [W/m2]
   real, allocatable, dimension(:) :: prsl1      ! pressure at forcing height [Pa]
   real, allocatable, dimension(:) :: srflag     ! snow ratio for precipitation [-]
   real, allocatable, dimension(:) :: prslki     ! Exner function at forcing height [-]
   real, allocatable, dimension(:) :: prslk1     ! Exner function at forcing height [-]
   real, allocatable, dimension(:) :: prsik1     ! Exner function at forcing height [-]
   real, allocatable, dimension(:) :: cmm        ! Cm*U [m/s]
   real, allocatable, dimension(:) :: chh        ! Ch*U*rho [kg/m2/s]
   real, allocatable, dimension(:) :: shdmin     ! minimum vegetation fraction(not used) [-]
   real, allocatable, dimension(:) :: smcref2    ! field capacity(not used) [m3/m3]
   real, allocatable, dimension(:) :: smcwlt2    ! wilting point(not used) [m3/m3]
   real, allocatable, dimension(:) :: snohf      ! snow melt energy that exist pack [W/m2]
   real, allocatable, dimension(:) :: sncovr1    !  copy of snow cover(not used)[-]
   real, allocatable, dimension(:) :: snoalb     ! snow-covered-area albedo(not used) [-]
   real, allocatable, dimension(:) :: tsurf      ! copy of tskin(not used) [K]
   real, allocatable, dimension(:) :: wet1       ! top-level soil saturation(not used) [-]
   real, allocatable, dimension(:) :: garea      ! grid cell area [m2]
   real, allocatable, dimension(:) :: rb1        ! composite bulk richardson number
   real, allocatable, dimension(:) :: fm1        ! composite momemtum stability
   real, allocatable, dimension(:) :: fh1        ! composite heat/moisture stability
   real, allocatable, dimension(:) :: stress1    ! composite surface stress
   real, allocatable, dimension(:) :: fm101      ! composite 2-meter momemtum stability
   real, allocatable, dimension(:) :: fh21       ! composite 10-meter heat/moisture stability
   real, allocatable, dimension(:) :: zvfun      ! some function of vegetation used for gfs stability
logical, allocatable, dimension(:) :: dry        ! land flag [-]
logical, allocatable, dimension(:) :: flag_iter  ! defunct flag for surface layer iteration [-]

logical :: thsfc_loc = .true.                    ! use local theta

integer                         :: lsnowl = -2   ! lower limit for snow vector
real(kind=kind_phys), parameter :: one     = 1.0_kind_phys

associate (                                                 &
   ps         => forcing%surface_pressure                  ,&
   t1         => forcing%temperature                       ,&
   q1         => forcing%specific_humidity                 ,&
   dlwflx     => forcing%downward_longwave                 ,&
   dswsfc     => forcing%downward_shortwave                ,&
   wind       => forcing%wind_speed                        ,&
   tprcp      => forcing%precipitation                     ,&
   im         => namelist%subset_length                    ,&
   km         => noahmp%static%soil_levels                 ,&
   delt       => noahmp%static%timestep                    ,&
   isot       => noahmp%static%soil_source                 ,&
   ivegsrc    => noahmp%static%veg_source                  ,&
   idveg      => noahmp%options%dynamic_vegetation         ,&
   iopt_crs   => noahmp%options%canopy_stomatal_resistance ,&
   iopt_btr   => noahmp%options%soil_wetness               ,&
   iopt_run   => noahmp%options%runoff                     ,&
   iopt_sfc   => noahmp%options%surface_exchange           ,&
   iopt_frz   => noahmp%options%supercooled_soilwater      ,&
   iopt_inf   => noahmp%options%frozen_soil_adjust         ,&
   iopt_rad   => noahmp%options%radiative_transfer         ,&
   iopt_alb   => noahmp%options%snow_albedo                ,&
   iopt_snf   => noahmp%options%precip_partition           ,&
   iopt_tbot  => noahmp%options%soil_temp_lower_bdy        ,&
   iopt_stc   => noahmp%options%soil_temp_time_scheme      ,&
   iopt_trs   => noahmp%options%thermal_roughness_scheme   ,&
   iopt_rsf   => noahmp%options%surface_evap_resistance    ,&
   iopt_gla   => noahmp%options%glacier                    ,&
   soiltyp    => noahmp%static%soil_category               ,&
   vegtype    => noahmp%static%vegetation_category         ,&
   slopetyp   => noahmp%static%slope_category              ,&
   sigmaf     => noahmp%model%vegetation_fraction          ,&
   emiss      => noahmp%diag%emissivity_total              ,&
   albdvis    => noahmp%diag%albedo_direct(:,1)            ,&
   albdnir    => noahmp%diag%albedo_direct(:,2)            ,&
   albivis    => noahmp%diag%albedo_diffuse(:,1)           ,&
   albinir    => noahmp%diag%albedo_diffuse(:,2)           ,&
   tg3        => noahmp%static%temperature_soil_bot        ,&
   cm         => noahmp%model%cm_noahmp                    ,&
   ch         => noahmp%model%ch_noahmp                    ,&
   shdmax     => noahmp%model%max_vegetation_frac          ,&
   sfalb      => noahmp%diag%albedo_total                  ,&
   zf         => noahmp%model%forcing_height               ,&
   weasd      => noahmp%state%snow_water_equiv             ,&
   snwdph     => noahmp%state%snow_depth                   ,&
   tskin      => noahmp%state%temperature_radiative        ,&
   canopy     => noahmp%diag%canopy_water                  ,&
   trans      => noahmp%flux%transpiration_heat            ,&
   zorl       => noahmp%diag%z0_total                      ,&
   ustar1     => noahmp%model%friction_velocity            ,&
   smc        => noahmp%state%soil_moisture_vol            ,&
   stc        => noahmp%state%temperature_soil             ,&
   slc        => noahmp%state%soil_liquid_vol              ,&
   qsurf      => noahmp%diag%spec_humidity_surface         ,&
   gflux      => noahmp%flux%ground_heat_total             ,&
   drain      => noahmp%flux%runoff_baseflow               ,&
   evap       => noahmp%flux%latent_heat_total             ,&
   hflx       => noahmp%flux%sensible_heat_total           ,&
   ep         => noahmp%diag%evaporation_potential         ,&
   runoff     => noahmp%flux%runoff_surface                ,&
   evbs       => noahmp%flux%latent_heat_ground            ,&
   evcw       => noahmp%flux%latent_heat_canopy            ,&
   sbsno      => noahmp%flux%snow_sublimation              ,&
   pah        => noahmp%flux%precip_adv_heat_total         ,&
   ecan       => noahmp%flux%evaporation_canopy            ,&
   etran      => noahmp%flux%transpiration                 ,&
   edir       => noahmp%flux%evaporation_soil              ,&
   snowc      => noahmp%diag%snow_cover_fraction           ,&
   stm        => noahmp%diag%soil_moisture_total           ,&
   xlatin     => noahmp%model%latitude                     ,&
   xcoszin    => noahmp%model%cosine_zenith                ,&
   iyrlen     => noahmp%model%year_length                  ,&
   julian     => noahmp%model%julian_day                   ,&
   rainn_mp   => noahmp%forcing%precip_non_convective      ,&
   rainc_mp   => noahmp%forcing%precip_convective          ,&
   snow_mp    => noahmp%forcing%precip_snow                ,&
   graupel_mp => noahmp%forcing%precip_graupel             ,&
   ice_mp     => noahmp%forcing%precip_hail                ,&
   snowxy     => noahmp%model%snow_levels                  ,&
   tvxy       => noahmp%state%temperature_leaf             ,&
   tgxy       => noahmp%state%temperature_ground           ,&
   canicexy   => noahmp%state%canopy_ice                   ,&
   canliqxy   => noahmp%state%canopy_liquid                ,&
   eahxy      => noahmp%state%vapor_pres_canopy_air        ,&
   tahxy      => noahmp%state%temperature_canopy_air       ,&
   cmxy       => noahmp%model%cm_noahmp                    ,&
   chxy       => noahmp%model%ch_noahmp                    ,&
   fwetxy     => noahmp%diag%canopy_wet_fraction           ,&
   sneqvoxy   => noahmp%state%snow_water_equiv_old         ,&
   alboldxy   => noahmp%diag%snow_albedo_old               ,&
   qsnowxy    => noahmp%forcing%snowfall                   ,&
   wslakexy   => noahmp%state%lake_water                   ,&
   zwtxy      => noahmp%diag%depth_water_table             ,&
   waxy       => noahmp%state%aquifer_water                ,&
   wtxy       => noahmp%state%saturated_water              ,&
   tsnoxy     => noahmp%state%temperature_snow             ,&
   zsnsoxy    => noahmp%model%interface_depth              ,&
   snicexy    => noahmp%state%snow_level_ice               ,&
   snliqxy    => noahmp%state%snow_level_liquid            ,&
   lfmassxy   => noahmp%state%leaf_carbon                  ,&
   rtmassxy   => noahmp%state%root_carbon                  ,&
   stmassxy   => noahmp%state%stem_carbon                  ,&
   woodxy     => noahmp%state%wood_carbon                  ,&
   stblcpxy   => noahmp%state%soil_carbon_stable           ,&
   fastcpxy   => noahmp%state%soil_carbon_fast             ,&
   xlaixy     => noahmp%model%leaf_area_index              ,&
   xsaixy     => noahmp%model%stem_area_index              ,&
   taussxy    => noahmp%state%snow_age                     ,&
   smoiseq    => noahmp%state%eq_soil_water_vol            ,&
   smcwtdxy   => noahmp%state%soil_moisture_wtd            ,&
   deeprechxy => noahmp%flux%deep_recharge                 ,&
   rechxy     => noahmp%flux%recharge                      ,&
   t2mmp      => noahmp%diag%temperature_2m                ,&
   q2mp       => noahmp%diag%spec_humidity_2m               &
   )

allocate(       rho(im))
allocate(        u1(im))
allocate(        v1(im))
allocate(      snet(im))
allocate(     prsl1(im))
allocate(    srflag(im))
allocate(    prslki(im))
allocate(    prslk1(im))
allocate(    prsik1(im))
allocate(       cmm(im))
allocate(       chh(im))
allocate(    shdmin(im))
allocate(   smcref2(im))
allocate(   smcwlt2(im))
allocate(     snohf(im))
allocate(   sncovr1(im))
allocate(    snoalb(im))
allocate(     tsurf(im))
allocate(      wet1(im))
allocate(       dry(im))
allocate(flag_iter (im))
allocate(     garea(im))
allocate(       rb1(im))
allocate(       fm1(im))
allocate(       fh1(im))
allocate(   stress1(im))
allocate(     fm101(im))
allocate(      fh21(im))
allocate(     zvfun(im))

dry        = .true.
  where(static%vegetation_category == static%iswater) dry = .false.
flag_iter  = .true.
garea      = 3000.0 * 3000.0   ! any size >= 3km will give the same answer

call set_soilveg(0,isot,ivegsrc,0)
call gpvs()

zorl     = z0_data(vegtype) * 100.0   ! at driver level, roughness length in cm

time_loop : do timestep = 1, namelist%run_timesteps

  now_time = namelist%initial_time + timestep * namelist%timestep_seconds

  call date_from_since("1970-01-01 00:00:00", now_time, now_date)
  read(now_date(1:4),'(i4)') now_yyyy
  iyrlen = 365
  if(mod(now_yyyy,4) == 0) iyrlen = 366
  
  if(.not.namelist%restart_simulation .and. timestep == 1) &
     call noahmp%InitStates(namelist, now_time)

  call forcing%ReadForcing(namelist, static, now_time)
  
  call interpolate_monthly(now_time, im, static%gvf_monthly, sigmaf)
  call interpolate_monthly(now_time, im, static%albedo_monthly, sfalb)
  
  call calc_cosine_zenith(now_time, im, static%latitude, static%longitude, xcoszin, julian)
  
  u1       = wind
  v1       = 0.0_kind_phys
  snet     = dswsfc * (1.0_kind_phys - sfalb)
  srflag   = 0.0d0
    where(t1 < tfreeze) srflag = 1.d0
  prsl1    = ps * exp(-1.d0*zf/29.25d0/t1)       !  29.26 [m/K] / T [K] is the atmospheric scale height
  prslki   = (exp(zf/29.25d0/t1))**(2.d0/7.d0)  
  prslk1   = (exp(zf/29.25d0/t1))**(2.d0/7.d0)   !  assuming Exner function is approximately constant
  prsik1   = (exp(zf/29.25d0/t1))**(2.d0/7.d0)   !   for these subtleties
  
  rainn_mp = 1000.0 * tprcp / delt
  rainc_mp = 0.0
  snow_mp = 0.0
  graupel_mp = 0.0
  ice_mp = 0.0

      call noahmpdrv_run                                               &
          ( im, km, lsnowl, itime, ps, u1, v1, t1, q1, soiltyp,        &
            vegtype,sigmaf, dlwflx, dswsfc, snet, delt, tg3, cm, ch,   &
            prsl1, prslk1, prslki, prsik1, zf, dry, wind, slopetyp,    &
            shdmin, shdmax, snoalb, sfalb, flag_iter,con_g,            &
            idveg, iopt_crs, iopt_btr, iopt_run, iopt_sfc, iopt_frz,   &
            iopt_inf, iopt_rad, iopt_alb, iopt_snf, iopt_tbot,         &
            iopt_stc, iopt_trs,xlatin, xcoszin, iyrlen, julian, garea, &
            rainn_mp, rainc_mp, snow_mp, graupel_mp, ice_mp,           &
            con_hvap, con_cp, con_jcal, rhoh2o, con_eps, con_epsm1,    &
            con_fvirt, con_rd, con_hfus, thsfc_loc,                    &
            weasd, snwdph, tskin, tprcp, srflag, smc, stc, slc,        &
            canopy, trans, tsurf, zorl,                                &
            rb1, fm1, fh1, ustar1, stress1, fm101, fh21,               &
            snowxy, tvxy, tgxy, canicexy, canliqxy, eahxy, tahxy, cmxy,&
            chxy, fwetxy, sneqvoxy, alboldxy, qsnowxy, wslakexy, zwtxy,&
            waxy, wtxy, tsnoxy, zsnsoxy, snicexy, snliqxy, lfmassxy,   &
            rtmassxy, stmassxy, woodxy, stblcpxy, fastcpxy, xlaixy,    &
            xsaixy, taussxy, smoiseq, smcwtdxy, deeprechxy, rechxy,    &
            albdvis, albdnir,  albivis,  albinir,emiss,                &
            sncovr1, qsurf, gflux, drain, evap, hflx, ep, runoff,      &
            cmm, chh, evbs, evcw, sbsno, pah, ecan, etran, edir, snowc,&
            stm, snohf,smcwlt2, smcref2, wet1, t2mmp, q2mp,zvfun,      &
            errmsg, errflg)     

  rho = prsl1 / (con_rd*t1*(one+con_fvirt*q1)) 
  hflx = hflx * rho * con_cp
  evap = evap * rho * con_hvap
  
  where(dswsfc>0.0 .and. sfalb<0.0) dswsfc = 0.0

  call output%WriteOutputNoahMP(namelist, noahmp, forcing, now_time)

  if(namelist%restart_timesteps > 0) then
    if(mod(timestep,namelist%restart_timesteps) == 0) then
      call restart%WriteRestartNoahMP(namelist, noahmp, now_time)
    end if
  end if

  if(errflg /= 0) then
    write(*,*) "noahmpdrv_run reporting an error"
    write(*,*) errmsg
    stop
  end if

end do time_loop

end associate

end subroutine ufsLandNoahMPDriverRun 

subroutine ufsLandNoahMPDriverFinalize()
end subroutine ufsLandNoahMPDriverFinalize

end module ufsLandNoahMPDriverModule
