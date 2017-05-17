!-----------------------------------------------------------------------------------!
!  this is the main driver of the code damocles.  it is included as a module        !
!  in order to allow it to be run from other programs e.g. python wrappers.         !
!  the run_damocles subroutine calls the subroutines that construct the grids,      !
!                                                                                   !
!  emit and propagate packets through the grid and collates all escaped packets.    !
!  the model comparison module is also called from here.                            !
!-----------------------------------------------------------------------------------!

module driver

    use globals
    use class_line
    use class_freq_grid
    use class_grid
    use electron_scattering
    use input
    use initialise
    use vector_functions
    use class_packet
    use radiative_transfer
    use model_comparison

    implicit none

contains

    subroutine run_damocles()

        integer, dimension(3) :: time

        !print start time
        call itime(time)
        print *, 'start time - ', time(2),'m', time(3),'s'

        !read input:
        call read_input()
        
        !construct grids and initialise simulation:
        do i_doublet=1,2

            !generate random seed for random number generators (ensures random numbers change on each run)
            call init_random_seed

            !construct all grids and initialise rest line wavelength/freq
            if (i_doublet==1) then
                !set active rest frame wavelength
                line%wavelength=line%doublet_wavelength_1
                line%frequency=c*10**9/line%wavelength

                !construct grids
                call itime(time)
                print *, 'input read time - ', time(2),'m', time(3),'s'
                call calculate_opacities()
                call itime(time)
                print *, 'opcaities calculated time - ', time(2),'m', time(3),'s'
                call build_dust_grid()
                call itime(time)
                print *, 'grid built time - ', time(2),'m', time(3),'s'
                call construct_freq_grid()
                call itime(time)
                print *, 'freq grid built time - ', time(2),'m', time(3),'s'
                call build_emissivity_dist()
                call itime(time)
                print *, 'emisivity grid built time - ', time(2),'m', time(3),'s'
                call n_e_const()
                call itime(time)
                print *, 'e- scat const time - ', time(2),'m', time(3),'s'

                !build multiple lines of sight array
                allocate(cos_theta_array(n_angle_divs))
                allocate(phi_array(n_angle_divs))
                do ii=1,n_angle_divs-1
                    cos_theta_array(ii) = (2*real(ii-1)/20.0)-1
                    phi_array(ii)=2*real(ii)*pi/20
                end do


                !initialise counters to zero
                n_init_packets=0
                n_inactive_packets=0
                n_abs_packets=0
                abs_frac=0
                n_los_packets=0

            else if (i_doublet==2) then
                !exit if not a doublet
                if (.not. lg_doublet) exit

                !otherwise reset rest frame wavelength of line to be modelled
                !active wavelength is now second component of doublet
                line%wavelength=line%doublet_wavelength_2
                line%frequency=c*10**9/line%wavelength
            end if

            call itime(time)
            print *, 'initialise time - ', time(2),'m', time(3),'s'

            !emit and propagate packets through grid
            print*,"propagating packets..."

            !entire simulation run for each component of doublet (if applicable)
            !absorbed weight stored for complete doublet (i.e. both components)
            !initialise absorbed weight of packets to zero
            abs_frac=0
            call omp_set_num_threads(num_threads)
            select case(gas_geometry%type)

                case('shell')
                    !if all emission from clumps within shell structure
                    if (gas_geometry%clumped_mass_frac == 1) then
                        do id_no=1,mothergrid%tot_cells
                            if (grid_cell(id_no)%lg_clump) then
                                !equal number of packets to be emitted in each clump
                                num_packets_array(id_no)=n_packets/n_clumps
                                n_init_packets=n_init_packets+num_packets_array(id_no)
                                call run_packets()
                            end if
                        end do
                    !else if all emission from smooth shell
                    else
                        do id_no=1,n_shells
                            n_init_packets=n_init_packets+num_packets_array(id_no)
                            call run_packets()
                            call itime(time)
                            print *, 'run time - shell no',id_no, time(2),'m', time(3),'s'
                        end do
                    end if

                case('arbitrary')
                    !emission per cell scaled with dust mass from specified dust grid
                    do id_no=1,mothergrid%tot_cells
                        !n is cumulative number of packets run through grid (check number)
                        n_init_packets=n_init_packets+num_packets_array(id_no)
                        call run_packets()
                    end do

                case default
                    print*,'you have not selected a shell or arbitrary distribution.  alternative distributions have not yet been included.'
                    print*,'please construct a grid using the gridmaker at http://www.nebulousresearch.org/codes/mocassin/mocassin_gridmaker.php and use the arbitrary option.  aborted.'
                    stop

            end select
        end do

        !calculate energies
        if (lg_doublet) then
            line%initial_energy=line%luminosity/real(2.0*n_init_packets-n_inactive_packets)
        else
            line%initial_energy=line%luminosity/real(n_init_packets-n_inactive_packets)
        end if

        !write out log file
        if (.not. lg_mcmc) call write_to_file()

        !calculate goodness of fit to data if supplied
        if (lg_data) then
            call read_in_data()
            call calculate_chi_sq()
        end if

        !decallocate all allocated memory
        deallocate(grid_cell)
        deallocate(nu_grid%lambda_bin)
        deallocate(nu_grid%vel_bin)
        deallocate(nu_grid%bin)
        deallocate(mothergrid%x_div)
        deallocate(mothergrid%y_div)
        deallocate(mothergrid%z_div)
        deallocate(num_packets_array)
        deallocate(profile_array)
        deallocate(dust%species)
        deallocate(cos_theta_array)
        deallocate(phi_array)
        deallocate(obs_data%vel)
        deallocate(obs_data%flux)
        deallocate(profile_los_array)
        deallocate(exclusion_zone)
        deallocate(model_rebinned%vel)
        deallocate(model_rebinned%flux)
        deallocate(model_rebinned%exclude)
        if (dust_geometry%type == "shell") deallocate(shell_radius)

        print*,'complete!'

    end subroutine run_damocles

    subroutine run_packets()

        !$OMP PARALLEL DEFAULT(SHARED) PRIVATE(ii,id_theta,id_phi,ixx,iyy,izz,thread_id)  REDUCTION(+:n_abs_packets,abs_frac,profile_array,profile_los_array,n_los_packets,n_inactive_packets)
        !$OMP DO

        do ii=1,num_packets_array(id_no)

            thread_id = omp_get_thread_num()
            !print*,thread_id,ii
            call emit_packet()

            if (packet%lg_active) then

                !propagate active packet through grid
                !call propagate()

                !if packet has been absorbed then record
                if (packet%lg_abs) then

                    n_abs_packets=n_abs_packets+1
                    if (i_doublet==2) then
                        abs_frac=abs_frac+packet%weight/line%doublet_ratio
                    else
                        abs_frac=abs_frac+packet%weight
                    end if

                else
                    !if the packet has not been absorbed then record in resultant profile

                    !if taking integrated profile and not interested in line of sight, record all escaped packets

                    if (.not. lg_los) then
                        call add_packet_to_profile()
                    else
                        !only add active packets to profile for those in los
                        if (packet%lg_los) call add_packet_to_profile()

                    end if !line of sight

                end if  !absorbed/escaped
            end if  !active
        end do
        !$OMP END DO
        !$OMP END PARALLEL

    end subroutine

    subroutine add_packet_to_profile()

        !find the smallest distance and thus nearest freq point
        packet%freq_id=minloc(packet%nu-nu_grid%bin(:,1),1,(packet%nu-nu_grid%bin(:,1))>0)

        if (packet%freq_id==0) then
            print*,'photon outside frequency range',packet%freq_id,packet%nu,packet%weight
        else
            !adjust weight of packet if second component of doublet
            if (i_doublet==2) then
                packet%weight=packet%weight/line%doublet_ratio
            end if
            !!$omp critical
            !add packet to primary profile array

            profile_array(packet%freq_id)=profile_array(packet%freq_id)+packet%weight

            if (lg_multi_los) then
                id_theta = minloc(packet%dir_sph(1)-cos_theta_array,1,(packet%dir_sph(1)-cos_theta_array)>0)
                id_phi = minloc(packet%dir_sph(2)-phi_array,1,(packet%dir_sph(2)-phi_array)>0)
                profile_los_array(packet%freq_id,id_theta,id_phi)=profile_los_array(packet%freq_id,id_theta,id_phi)+packet%weight
            end if

            !incremement number of packets in line of sight
            n_los_packets=n_los_packets+1
            !!$omp end critical
        end if

    end subroutine

end module driver


