!---------------------------------------------------------------------------------!
!  this module declares the packet derived type object which descibes properties  !
!  of the packet that is currently being processed throught the ejecta            !
!                                                                                 !
!  the subroutine 'emit_packet' generates this packet and assigns its initial     !
!  properties and is called directly from the driver                              !
!---------------------------------------------------------------------------------!

module class_packet

    use globals
    use class_grid
    use input
    use initialise
    use vector_functions

    implicit none

    type packet_obj
        real    ::  r            !current radius of packet location in cm
        real    ::  v            !current (scalar) velocity of packet in km/s
        real    ::  nu           !current frequency of packet
        real    ::  weight       !current weighting of packet

        real    ::  vel_vect(3)  !current velocity vector of packet in cartesian (km/s)
        real    ::  dir_cart(3)  !current direction of propagation of packet in cartesian coordinates
        real    ::  pos_cart(3)  !current position of packet in cartesian coordinates
        real    ::  dir_sph(2)   !current direction of propagation in spherical coordinates
        real    ::  pos_sph(3)   !current position of packet in spherical coordinates

        integer ::  cell_no      !current cell id of packet
        integer ::  axis_no(3)   !current cell ids in each axis
        integer ::  step_no      !number of steps that packet has experienced
        integer ::  freq_id      !id of frequency grid division that contains the frequency of the packet

        logical ::  lg_abs       !true indicates packet has been absored
        logical ::  lg_los       !true indicates packet is in line of sight (after it has escaped)
        logical ::  lg_active    !true indicates that packet is being or has been processed
                                 !false indidcates it was outside of ejecta and therefore inactive, or has been scattered too many times
    end type

    type(packet_obj) :: packet
    save packet
    !$OMP THREADPRIVATE(packet)
contains

    !this subroutine generates a packet and samples an emission position in the observer's rest frame
    !a propagation direction is sampled from an isotropic distribution in the comoving frame of the emitter
    !and a frequency is assigned in this frame
    !frequency and propagation direction are updated in observer's rest frame and grid cell containing packet is identified
    subroutine emit_packet()

        implicit none

        call random_number(random)

        !packets are weighted according to their frequency shit (energy is altered when doppler shifted)
        packet%weight=1

        !packet is declared inactive by default until declared active
        packet%lg_active=.false.

        !initialise absorption logical to 0.  this changed to 1 if absorbed.
        !note absorption (lg_abs = true - absorbed) different to inactive (lg_active = false - never emitted).
        packet%lg_abs=.false.

        !initialise step number to zero
        packet%step_no=0

        !initial position of packet is generated in both cartesian and spherical coordinates
        if ((gas_geometry%clumped_mass_frac==1) .or. (gas_geometry%type == "arbitrary")) then
            !packets are emitted from grid cells
            packet%pos_cart= (grid_cell(id_no)%axis+random(1:3)*grid_cell(id_no)%width)
            packet%pos_sph(1)=((packet%pos_cart(1)**2+packet%pos_cart(2)**2+packet%pos_cart(3)**2)**0.5)*1e-15
            packet%pos_sph(2)=atan(packet%pos_cart(2)/packet%pos_cart(1))
            packet%pos_sph(3)=acos(packet%pos_cart(3)*1e-15/packet%pos_sph(1))
            packet%pos_cart(:)=packet%pos_cart(:)*1e-15
        else
            !shell emissivity distribution
            packet%pos_sph(:)=(/ (random(1)*(gas_geometry%r_max-gas_geometry%r_min)/n_shells+shell_radius(id_no,1)),(2*random(2)-1),random(3)*2*pi/)       !position of emitter idp - spherical coords - system sn - rf
            packet%pos_cart(:)=cartr(packet%pos_sph(1),acos(packet%pos_sph(2)),packet%pos_sph(3))
        end if

        !generate an initial propagation direction from an isotropic distribution
        !in comoving frame of emitting particle
        packet%dir_sph(:)=(/ (2*random(4))-1,random(5)*2*pi /)
        packet%dir_cart(:)=cart(acos(packet%dir_sph(1)),packet%dir_sph(2))

        !if the photon lies inside the radial bounds of the supernova
        !or if the photon is emitted from a clump or cell (rather than shell) then it is processed
        if (((packet%pos_sph(1) > gas_geometry%r_min) .and. (packet%pos_sph(1) < gas_geometry%r_max) .and. (gas_geometry%clumped_mass_frac==0)) &
            & .or. (gas_geometry%clumped_mass_frac==1) &
            & .or. (gas_geometry%type == 'arbitrary')) then

            !calculate velocity of emitting particle from radial velocity distribution
            !velocity vector comes from radial position vector of particle
            packet%v=gas_geometry%v_max*((packet%pos_sph(1)/gas_geometry%r_max)**gas_geometry%v_power)
            packet%vel_vect=normalise(packet%pos_cart)*packet%v

            packet%nu=line%frequency
            packet%lg_active=.true.

            call lorentz_trans(packet%vel_vect,packet%dir_cart,packet%nu,packet%weight,"emsn")

            !identify cell which contains emitting particle (and therefore packet)
            !!could be made more efficient but works...
            do ixx=1,mothergrid%n_cells(1)
                if ((packet%pos_cart(1)*1e15-mothergrid%x_div(ixx))<0) then  !identify grid axis that lies just beyond position of emitter in each direction
                    packet%axis_no(1)=ixx-1                                  !then the grid cell id is the previous one
                    exit
                end if
                if (ixx==mothergrid%n_cells(1)) then
                    packet%axis_no(1)=mothergrid%n_cells(1)
                end if

            end do
            do iyy=1,mothergrid%n_cells(2)
                if ((packet%pos_cart(2)*1e15-mothergrid%y_div(iyy))<0) then
                    packet%axis_no(2)=iyy-1
                    exit
                end if
                if (iyy==mothergrid%n_cells(2)) then
                    packet%axis_no(2)=mothergrid%n_cells(2)
                end if

            end do
            do izz=1,mothergrid%n_cells(3)
                if ((packet%pos_cart(3)*1e15-mothergrid%z_div(izz))<0) then
                    packet%axis_no(3)=izz-1
                    !print*,packet%pos_cart(3),mothergrid%z_div(izz)
                    exit
                end if
                if (izz==mothergrid%n_cells(3)) then
                    packet%axis_no(3)=mothergrid%n_cells(3)
                end if
            end do

            !check to ensure that for packets emitted from cells, the identified cell is the same as the original...
            if ((gas_geometry%type == 'shell' .and. gas_geometry%clumped_mass_frac == 1) &
                &    .or.  (gas_geometry%type == 'arbitrary')) then

                if ((packet%axis_no(1) /= grid_cell(id_no)%id(1)) .and. &
                    &   (packet%axis_no(2) /= grid_cell(id_no)%id(2)) .and. &
                    &   (packet%axis_no(3) /= grid_cell(id_no)%id(3))) then
                    print*,'cell calculation gone wrong in module init_packet. aborted.'
                    stop
                end if
            end if
        !if the photon lies outside the bounds of the sn then it is inactive and not processed
        else
            !track total number of inactive photons
            n_inactive_packets=n_inactive_packets+1
            print*,'inactive photon'
            packet%lg_active=.false.
        end if

        if (any(packet%axis_no == 0)) then
            packet%lg_active=.false.
            n_inactive_packets=n_inactive_packets+1
            print*,'inactive photon'
        end if

        if (n_inactive_packets/n_init_packets > 0.1) print*, 'warning: number of inactive packets greater than 10% of number requested.'

        packet%pos_cart=packet%pos_cart*1e15

    end subroutine emit_packet

end module class_packet
