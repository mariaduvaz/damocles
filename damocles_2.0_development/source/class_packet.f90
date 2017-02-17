!---------------------------------------------------------------------------------!
!  this module declares the packet derived type object which descibes properties  !
!  of the packet that is currently being processed throught the ejecta            !
!                                                                                 !
!  the subroutine 'emit_packet' generates this packet and assigns its initial     !
!  properties and is called directly from the driver                              !
!---------------------------------------------------------------------------------!

MODULE class_packet

    use globals
    use class_grid
    use input
    use initialise
    use vector_functions

    IMPLICIT NONE

    TYPE packet_obj
        REAL    ::  r            !current radius of packet location in cm
        REAL    ::  v            !current (scalar) velocity of packet in km/s
        REAL    ::  nu           !current frequency of packet
        REAL    ::  weight       !current weighting of packet

        REAL    ::  vel_vect(3)  !current velocity vector of packet in cartesian (km/s)
        REAL    ::  dir_cart(3)  !current direction of propagation of packet in cartesian coordinates
        REAL    ::  pos_cart(3)  !current position of packet in cartesian coordinates
        REAL    ::  dir_sph(2)   !current direction of propagation in spherical coordinates
        REAL    ::  pos_sph(3)   !current position of packet in spherical coordinates

        INTEGER ::  cell_no      !current cell ID of packet
        INTEGER ::  axis_no(3)   !current cell IDs in each axis
        INTEGER ::  step_no      !number of steps that packet has experienced
        INTEGER ::  freq_id      !id of frequency grid division that contains the frequency of the packet

        LOGICAL ::  lg_abs       !true indicates packet has been absored
        LOGICAL ::  lg_los       !true indicates packet is in line of sight (after it has escaped)
        LOGICAL ::  lg_active    !true indicates that packet is being or has been processed
                                 !false indidcates it was outside of ejecta and therefore inactive, or has been scattered too many times
    END TYPE

    TYPE(packet_obj) :: packet

contains

    !this subroutine generates a packet and samples an emission position in the observer's rest frame
    !a propagation direction is sampled from an isotropic distribution in the comoving frame of the emitter
    !and a frequency is assigned in this frame
    !frequency and propagation direction are updated in observer's rest frame and grid cell containing packet is identified
    SUBROUTINE emit_packet()

        IMPLICIT NONE

        CALL RANDOM_NUMBER(random)

        !packets are weighted according to their frequency shit (energy is altered when doppler shifted)
        packet%weight=1

        !packet is declared inactive by default until declared active
        packet%lg_active=.false.

        !initialise absorption logical to 0.  This changed to 1 if absorbed.
        !Note absorption (lg_abs = true - absorbed) different to inactive (lg_active = false - never emitted).
        packet%lg_abs=.false.

        !initialise step number to zero
        packet%step_no=0

        !initial position of packet is generated in both cartesian and spherical coordinates
        IF ((gas_geometry%clumped_mass_frac==1) .or. (gas_geometry%type == "arbitrary")) THEN
            !packets are emitted from grid cells
            packet%pos_cart= (grid_cell(id_no)%axis+random(1:3)*grid_cell(id_no)%width)
            packet%pos_sph(1)=((packet%pos_cart(1)**2+packet%pos_cart(2)**2+packet%pos_cart(3)**2)**0.5)*1e-15
            packet%pos_sph(2)=ATAN(packet%pos_cart(2)/packet%pos_cart(1))
            packet%pos_sph(3)=ACOS(packet%pos_cart(3)*1e-15/packet%pos_sph(1))
            packet%pos_cart(:)=packet%pos_cart(:)*1e-15
        ELSE
            !shell emissivity distribution
            packet%pos_sph(:)=(/ (random(1)*shell_width+RSh(id_no,1)),(2*random(2)-1),random(3)*2*pi/)       !position of emitter idP - spherical coords - system SN - RF
            packet%pos_cart(:)=cartr(packet%pos_sph(1),ACOS(packet%pos_sph(2)),packet%pos_sph(3))
        END IF

        !generate an initial propagation direction from an isotropic distribution
        !in comoving frame of emitting particle
        packet%dir_sph(:)=(/ (2*random(4))-1,random(5)*2*pi /)
        packet%dir_cart(:)=cart(ACOS(packet%dir_sph(1)),packet%dir_sph(2))

        !If the photon lies inside the radial bounds of the supernova
        !or if the photon is emitted from a clump or cell (rather than shell) then it is processed
        IF (((packet%pos_sph(1) > gas_geometry%R_min) .AND. (packet%pos_sph(1) < gas_geometry%R_max) .AND. (gas_geometry%clumped_mass_frac==0)) &
            & .OR. (gas_geometry%clumped_mass_frac==1) &
            & .OR. (gas_geometry%type == 'arbitrary')) THEN

            !calculate velocity of emitting particle from radial velocity distribution
            !velocity vector comes from radial position vector of particle
            packet%v=gas_geometry%v_max*((packet%pos_sph(1)/gas_geometry%R_max)**gas_geometry%v_power)
            packet%vel_vect=normalise(packet%pos_cart)*packet%v

            packet%nu=line%frequency
            packet%lg_active=.true.

            call lorentz_trans(packet%vel_vect,packet%dir_cart,packet%nu,packet%weight,"emsn")

            !identify cell which contains emitting particle (and therefore packet)
            !!could be made more efficient but works...
            DO ixx=1,mothergrid%n_cells(1)
                IF ((packet%pos_cart(1)*1e15-mothergrid%x_div(ixx))<0) THEN  !identify grid axis that lies just beyond position of emitter in each direction
                    packet%axis_no(1)=ixx-1                                  !then the grid cell id is the previous one
                    EXIT
                END IF
                IF (ixx==mothergrid%n_cells(1)) THEN
                    packet%axis_no(1)=mothergrid%n_cells(1)
                END IF

            END DO
            DO iyy=1,mothergrid%n_cells(2)
                IF ((packet%pos_cart(2)*1e15-mothergrid%y_div(iyy))<0) THEN
                    packet%axis_no(2)=iyy-1
                    EXIT
                END IF
                IF (iyy==mothergrid%n_cells(2)) THEN
                    packet%axis_no(2)=mothergrid%n_cells(2)
                END IF

            END DO
            DO izz=1,mothergrid%n_cells(3)
                IF ((packet%pos_cart(3)*1e15-mothergrid%z_div(izz))<0) THEN
                    packet%axis_no(3)=izz-1
                    !PRINT*,packet%pos_cart(3),mothergrid%z_div(izz)
                    EXIT
                END IF
                IF (izz==mothergrid%n_cells(3)) THEN
                    packet%axis_no(3)=mothergrid%n_cells(3)
                END IF
            END DO

            !check to ensure that for packets emitted from cells, the identified cell is the same as the original...
            IF ((gas_geometry%type == 'shell' .and. gas_geometry%clumped_mass_frac == 1) &
                &    .or.  (gas_geometry%type == 'arbitrary')) THEN

                IF ((packet%axis_no(1) /= grid_cell(id_no)%id(1)) .and. &
                    &   (packet%axis_no(2) /= grid_cell(id_no)%id(2)) .and. &
                    &   (packet%axis_no(3) /= grid_cell(id_no)%id(3))) THEN
                    PRINT*,'cell calculation gone wrong in module init_packet. Aborted.'
                    STOP
                END IF
            END IF
        !If the photon lies outside the bounds of the SN then it is inactive and not processed
        ELSE
            !track total number of inactive photons
            n_inactive=n_inactive+1
            PRINT*,'inactive photon'
            packet%lg_active=.false.
        END IF

        IF (ANY(packet%axis_no == 0)) THEN
            packet%lg_active=.false.
            n_inactive=n_inactive+1
            PRINT*,'inactive photon'
        END IF

        IF (n_inactive/n_packets > 0.1) PRINT*, 'Warning: number of inactive packets greater than 10% of number requested.'

        packet%pos_cart=packet%pos_cart*1e15

    END SUBROUTINE emit_packet

END MODULE class_packet